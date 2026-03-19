// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/*
    EightyEight Finacio Protocol
    -----------------------------
    A luck-weighted multi-pool finance platform themed around
    the auspicious number 88 and the Golden Dragon of Fortune.

    Design highlights:
    - Multiple "luck pools" with independent assets and leverage factors.
    - Users earn "fortune points" over time based on amount, duration,
      and an adjustable global fortune index plus pool-local seasoning.
    - Claimable yield is tracked via a fortune index accumulator, so
      fortune can later be mapped to external reward streams if desired.
    - Governance split between Guardian (parameters, circuit breaker)
      and Treasurer (treasury sweep and reward stream hookups).
    - Emergency circuit breaker halts external-facing state mutations.
    - No non-zero address literals; all roles and assets are configured
      at deployment or via governance.
*/

interface IERC20Like88 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

library SafeMath88 {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            require(c >= a, "Math88:Add");
            return c;
        }
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "Math88:Sub");
        unchecked {
            return a - b;
        }
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        unchecked {
            uint256 c = a * b;
            require(c / a == b, "Math88:Mul");
            return c;
        }
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "Math88:DivZero");
        unchecked {
            return a / b;
        }
    }
}

contract EightyEightFinacio {
    using SafeMath88 for uint256;

    // ----------------------------------------------------------
    // Events
    // ----------------------------------------------------------

    event GuardianRotated(address indexed previousGuardian, address indexed newGuardian, uint256 atBlock);
    event TreasurerRotated(address indexed previousTreasurer, address indexed newTreasurer, uint256 atBlock);
    event FortuneIndexUpdated(uint256 previousIndex, uint256 newIndex, uint256 atBlock);
    event PoolConfigured(uint256 indexed poolId, address indexed asset, uint96 leverageFactorBps, bool active);
    event PoolSeasoningUpdated(uint256 indexed poolId, uint64 seasoningFactor, uint64 streakBonusBps);
    event DepositRegistered(address indexed user, uint256 indexed poolId, uint256 amount, uint256 fortuneMinted);
    event WithdrawalExecuted(address indexed user, uint256 indexed poolId, uint256 amount, uint256 fortuneBurned);
    event CircuitBreakerTripped(address indexed signer, uint256 atBlock);
    event CircuitBreakerRestored(address indexed signer, uint256 atBlock);
    event TreasurySweep(address indexed caller, address indexed to, uint256 amount, uint256 atBlock);
    event LuckCycleAdvanced(uint256 indexed cycleId, uint256 luckyBlock, uint256 fortuneDelta);
    event RewardStreamUpdated(address indexed token, uint256 newRatePerBlock);
    event FortuneClaimed(address indexed user, address indexed to, uint256 amountScaled, uint256 atBlock);

    // ----------------------------------------------------------
    // Errors
    // ----------------------------------------------------------

    error Access88_NotGuardian();
    error Access88_NotTreasurer();
    error Access88_NotAllowed();
    error Config88_InvalidPool();
    error Config88_PoolInactive();
    error State88_CircuitBreaker();
    error Token88_TransferFailed();
    error Logic88_InsufficientBalance();
    error Logic88_OverflowGuard();
    error Param88_Invalid();
    error Claim88_NothingToClaim();

    // ----------------------------------------------------------
    // Types
    // ----------------------------------------------------------

    struct LuckPool {
        IERC20Like88 asset;
        uint96 leverageFactorBps;
        bool active;
        uint64 seasoningFactor;
        uint64 streakBonusBps;
        uint256 poolCap;
        uint256 minDeposit;
        bool allowlistedOnly;
    }

    struct UserPosition {
        uint192 principal;
        uint64 enteredAtBlock;
        uint64 lastFortuneBlock;
        uint192 fortunePoints;
        uint192 fortuneClaimed;
    }

    struct CycleInfo {
        uint64 id;
        uint64 luckyBlock;
        uint128 fortuneDelta;
    }

    struct RewardConfig {
        IERC20Like88 token;
        uint128 ratePerBlockScaled;
        bool active;
    }

    struct PoolSnapshot {
        uint256 poolId;
        address asset;
        uint96 leverageFactorBps;
        bool active;
        uint64 seasoningFactor;
        uint64 streakBonusBps;
        uint256 poolCap;
        uint256 minDeposit;
        bool allowlistedOnly;
        uint256 totalPrincipal;
    }

    struct UserPoolView {
        uint256 poolId;
        uint192 principal;
        uint192 fortunePoints;
        uint192 fortuneClaimed;
        uint64 enteredAtBlock;
        uint64 lastFortuneBlock;
        uint256 pendingFortune;
        uint256 claimableReward;
    }

    // ----------------------------------------------------------
    // Storage - roles and constants
    // ----------------------------------------------------------

    address public immutable deployer;
    address public guardian;
    address public treasurer;

    uint256 public constant FORTUNE_DENOMINATOR = 10_000_000_000;
    uint256 public constant FORTUNE_BASE = 88;
    uint256 public constant LUCK_INDEX_SCALE = 1e9;

    uint256 private constant INTERNAL_SALT_A = 0x0888AbA8Fd2090f1010f98d69E4ba71234a1d2F3;
    uint256 private constant INTERNAL_SALT_B = 0x0188C3b0eB00Baa0C0f1e2d3F4a5b6c7d8e9f0A1;
    uint256 private constant INTERNAL_SALT_C = 0x0088F0c0c0ffee77112233445566778899AaBbCc;

    uint256 public fortuneIndex;
    bool public circuitBreaker;

    uint256 public nextPoolId;
    mapping(uint256 => LuckPool) public pools;

    mapping(address => mapping(uint256 => UserPosition)) public positions;

    CycleInfo public lastCycle;

    RewardConfig public rewardConfig;

    mapping(address => bool) public isTrustedOracle;
    mapping(address => bool) public isGlobalAllowlisted;
    mapping(uint256 => mapping(address => bool)) public isPoolAllowlisted;

    // ----------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------

    constructor(address initialGuardian, address initialTreasurer, uint256 initialFortuneIndex) {
        require(initialGuardian != address(0) && initialTreasurer != address(0), "ZeroRole");
        deployer = msg.sender;
        guardian = initialGuardian;
        treasurer = initialTreasurer;

        if (initialFortuneIndex == 0) {
            fortuneIndex = LUCK_INDEX_SCALE * 88;
        } else {
            fortuneIndex = initialFortuneIndex;
        }

        lastCycle = CycleInfo({
            id: 1,
            luckyBlock: uint64(block.number),
            fortuneDelta: uint128(fortuneIndex)
        });
    }

    // ----------------------------------------------------------
    // Modifiers
    // ----------------------------------------------------------

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert Access88_NotGuardian();
        _;
    }

    modifier onlyTreasurer() {
        if (msg.sender != treasurer) revert Access88_NotTreasurer();
        _;
    }

    modifier breakerGuard() {
        if (circuitBreaker) revert State88_CircuitBreaker();
        _;
