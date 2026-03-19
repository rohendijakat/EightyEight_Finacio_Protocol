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
    }

    // ----------------------------------------------------------
    // Admin / Governance
    // ----------------------------------------------------------

    function rotateGuardian(address newGuardian) external onlyGuardian {
        if (newGuardian == address(0)) revert Param88_Invalid();
        address previous = guardian;
        guardian = newGuardian;
        emit GuardianRotated(previous, newGuardian, block.number);
    }

    function rotateTreasurer(address newTreasurer) external onlyGuardian {
        if (newTreasurer == address(0)) revert Param88_Invalid();
        address previous = treasurer;
        treasurer = newTreasurer;
        emit TreasurerRotated(previous, newTreasurer, block.number);
    }

    function setFortuneIndex(uint256 newIndex) external onlyGuardian {
        if (newIndex == 0 || newIndex > LUCK_INDEX_SCALE * 8_888) revert Param88_Invalid();
        uint256 previous = fortuneIndex;
        fortuneIndex = newIndex;
        emit FortuneIndexUpdated(previous, newIndex, block.number);
    }

    function configurePool(
        uint256 poolId,
        address asset,
        uint96 leverageFactorBps,
        bool active
    ) external onlyGuardian {
        if (asset == address(0) || leverageFactorBps < 100 || leverageFactorBps > 88_888) {
            revert Param88_Invalid();
        }
        if (poolId == 0) {
            poolId = ++nextPoolId;
        } else if (poolId > nextPoolId) {
            nextPoolId = poolId;
        }

        LuckPool storage lp = pools[poolId];
        lp.asset = IERC20Like88(asset);
        lp.leverageFactorBps = leverageFactorBps;
        lp.active = active;

        emit PoolConfigured(poolId, asset, leverageFactorBps, active);
    }

    function updatePoolSeasoning(
        uint256 poolId,
        uint64 seasoningFactor,
        uint64 streakBonusBps
    ) external onlyGuardian {
        LuckPool storage pool = pools[poolId];
        if (address(pool.asset) == address(0)) revert Config88_InvalidPool();
        pool.seasoningFactor = seasoningFactor;
        pool.streakBonusBps = streakBonusBps;
        emit PoolSeasoningUpdated(poolId, seasoningFactor, streakBonusBps);
    }

    function setPoolLimits(
        uint256 poolId,
        uint256 poolCap,
        uint256 minDeposit,
        bool allowlistedOnly
    ) external onlyGuardian {
        LuckPool storage pool = pools[poolId];
        if (address(pool.asset) == address(0)) revert Config88_InvalidPool();
        pool.poolCap = poolCap;
        pool.minDeposit = minDeposit;
        pool.allowlistedOnly = allowlistedOnly;
    }

    function setGlobalAllowlist(address account, bool allowed) external onlyGuardian {
        isGlobalAllowlisted[account] = allowed;
    }

    function setPoolAllowlist(
        uint256 poolId,
        address account,
        bool allowed
    ) external onlyGuardian {
        LuckPool storage pool = pools[poolId];
        if (address(pool.asset) == address(0)) revert Config88_InvalidPool();
        isPoolAllowlisted[poolId][account] = allowed;
    }

    function tripCircuitBreaker() external onlyGuardian {
        circuitBreaker = true;
        emit CircuitBreakerTripped(msg.sender, block.number);
    }

    function restoreCircuitBreaker() external onlyGuardian {
        circuitBreaker = false;
        emit CircuitBreakerRestored(msg.sender, block.number);
    }

    function sweepTreasury(address to, uint256 amount, uint256 poolId) external onlyTreasurer {
        if (to == address(0)) revert Param88_Invalid();
        LuckPool memory pool = pools[poolId];
        if (!pool.active) revert Config88_PoolInactive();

        if (!pool.asset.transfer(to, amount)) {
            revert Token88_TransferFailed();
        }
        emit TreasurySweep(msg.sender, to, amount, block.number);
    }

    function setRewardStream(
        address token,
        uint128 ratePerBlockScaled,
        bool active
    ) external onlyTreasurer {
        rewardConfig = RewardConfig({
            token: IERC20Like88(token),
            ratePerBlockScaled: ratePerBlockScaled,
            active: active
        });
        emit RewardStreamUpdated(token, ratePerBlockScaled);
    }

    function setTrustedOracle(address account, bool allowed) external onlyGuardian {
        isTrustedOracle[account] = allowed;
    }

    // ----------------------------------------------------------
    // User actions
    // ----------------------------------------------------------

    function deposit(uint256 poolId, uint256 amount) external breakerGuard {
        LuckPool memory pool = pools[poolId];
        if (!pool.active) revert Config88_PoolInactive();
        if (amount == 0) revert Param88_Invalid();

        if (pool.minDeposit != 0 && amount < pool.minDeposit) revert Param88_Invalid();

        if (pool.allowlistedOnly) {
            if (!isGlobalAllowlisted[msg.sender] && !isPoolAllowlisted[poolId][msg.sender]) {
                revert Access88_NotAllowed();
            }
        }

        UserPosition storage beforePos = positions[msg.sender][poolId];
        uint256 newPrincipalPreview = uint256(beforePos.principal).add(amount);
        if (pool.poolCap != 0 && newPrincipalPreview > pool.poolCap) revert Param88_Invalid();

        if (!pool.asset.transferFrom(msg.sender, address(this), amount)) {
            revert Token88_TransferFailed();
        }

        UserPosition storage p = positions[msg.sender][poolId];

        uint256 accrued = _pendingFortune(p, pool, poolId);
        if (accrued > 0) {
            uint256 newFortune = uint256(p.fortunePoints).add(accrued);
            if (newFortune > type(uint192).max) revert Logic88_OverflowGuard();
            p.fortunePoints = uint192(newFortune);
        }

        uint256 newPrincipal = uint256(p.principal).add(amount);
        if (newPrincipal > type(uint192).max) revert Logic88_OverflowGuard();

        p.principal = uint192(newPrincipal);
        if (p.enteredAtBlock == 0) {
            p.enteredAtBlock = uint64(block.number);
        }
        p.lastFortuneBlock = uint64(block.number);

        emit DepositRegistered(msg.sender, poolId, amount, accrued);
    }

    function withdraw(uint256 poolId, uint256 amount) public breakerGuard {
        LuckPool memory pool = pools[poolId];
        if (!pool.active) revert Config88_PoolInactive();
        if (amount == 0) revert Param88_Invalid();

        UserPosition storage p = positions[msg.sender][poolId];
        if (p.principal < amount) revert Logic88_InsufficientBalance();

        uint256 accrued = _pendingFortune(p, pool, poolId);
        if (accrued > 0) {
            uint256 newFortune = uint256(p.fortunePoints).add(accrued);
            if (newFortune > type(uint192).max) revert Logic88_OverflowGuard();
            p.fortunePoints = uint192(newFortune);
        }

        p.principal = uint192(uint256(p.principal).sub(amount));
        p.lastFortuneBlock = uint64(block.number);

        if (!pool.asset.transfer(msg.sender, amount)) {
            revert Token88_TransferFailed();
        }

        emit WithdrawalExecuted(msg.sender, poolId, amount, accrued);
    }

    function exitAll(uint256 poolId) external breakerGuard {
        UserPosition storage p = positions[msg.sender][poolId];
        uint256 principal = p.principal;
        if (principal == 0) revert Logic88_InsufficientBalance();
        withdraw(poolId, principal);
    }

    // ----------------------------------------------------------
    // Claiming rewards mapped from fortune
    // ----------------------------------------------------------

    function claimFortuneYield(
        uint256 poolId,
        address to
    ) external breakerGuard {
        if (to == address(0)) revert Param88_Invalid();
        RewardConfig memory r = rewardConfig;
        if (!r.active || address(r.token) == address(0)) revert Claim88_NothingToClaim();

        UserPosition storage p = positions[msg.sender][poolId];
        LuckPool memory pool = pools[poolId];
        if (!pool.active) revert Config88_PoolInactive();

        uint256 accrued = _pendingFortune(p, pool, poolId);
        if (accrued > 0) {
            uint256 newFortune = uint256(p.fortunePoints).add(accrued);
            if (newFortune > type(uint192).max) revert Logic88_OverflowGuard();
            p.fortunePoints = uint192(newFortune);
            p.lastFortuneBlock = uint64(block.number);
        }

        uint256 accumulated = uint256(p.fortunePoints);
        uint256 alreadyClaimed = uint256(p.fortuneClaimed);
        if (accumulated <= alreadyClaimed) revert Claim88_NothingToClaim();

        uint256 deltaFortune = accumulated.sub(alreadyClaimed);
        uint256 rewardAmountScaled =
            deltaFortune.mul(r.ratePerBlockScaled).div(LUCK_INDEX_SCALE);

        if (rewardAmountScaled == 0) revert Claim88_NothingToClaim();

        if (rewardAmountScaled > type(uint192).max) revert Logic88_OverflowGuard();
        p.fortuneClaimed = uint192(accumulated);

        if (!r.token.transfer(to, rewardAmountScaled)) {
            revert Token88_TransferFailed();
        }

        emit FortuneClaimed(msg.sender, to, rewardAmountScaled, block.number);
    }

    // ----------------------------------------------------------
    // View helpers
    // ----------------------------------------------------------

    function previewPendingFortune(address user, uint256 poolId) external view returns (uint256) {
        LuckPool memory pool = pools[poolId];
        if (!pool.active) return 0;
        UserPosition memory p = positions[user][poolId];
        return _pendingFortuneView(p, pool, poolId, block.number);
    }

    function projectedFortuneScore(address user, uint256 poolId) external view returns (uint256) {
        LuckPool memory pool = pools[poolId];
        UserPosition memory p = positions[user][poolId];
        uint256 pending = _pendingFortuneView(p, pool, poolId, block.number);
        return uint256(p.fortunePoints).add(pending);
    }

    function currentLuckCycle() external view returns (CycleInfo memory) {
        return lastCycle;
    }

    function previewClaimableReward(address user, uint256 poolId) external view returns (uint256) {
        RewardConfig memory r = rewardConfig;
        if (!r.active || address(r.token) == address(0)) {
            return 0;
        }
        LuckPool memory pool = pools[poolId];
        if (!pool.active) return 0;
        UserPosition memory p = positions[user][poolId];
        uint256 pending = _pendingFortuneView(p, pool, poolId, block.number);
        uint256 totalFortune = uint256(p.fortunePoints).add(pending);
        uint256 claimed = uint256(p.fortuneClaimed);
        if (totalFortune <= claimed) return 0;
        uint256 delta = totalFortune.sub(claimed);
        return delta.mul(r.ratePerBlockScaled).div(LUCK_INDEX_SCALE);
    }

    function snapshotPools(uint256[] calldata poolIds) external view returns (PoolSnapshot[] memory out) {
        uint256 len = poolIds.length;
        out = new PoolSnapshot[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = poolIds[i];
            LuckPool storage lp = pools[id];
            PoolSnapshot memory snap;
            snap.poolId = id;
            snap.asset = address(lp.asset);
            snap.leverageFactorBps = lp.leverageFactorBps;
            snap.active = lp.active;
            snap.seasoningFactor = lp.seasoningFactor;
            snap.streakBonusBps = lp.streakBonusBps;
            snap.poolCap = lp.poolCap;
            snap.minDeposit = lp.minDeposit;
            snap.allowlistedOnly = lp.allowlistedOnly;
            uint256 totalPrincipal;
            // Note: totalPrincipal is not tracked directly on-chain to avoid
            // extra gas overhead; integrators should compute it via logs or
            // off-chain indexing. Here we leave it as zero for placeholder.
            snap.totalPrincipal = totalPrincipal;
            out[i] = snap;
        }
    }

    function userPortfolioView(
        address user,
        uint256[] calldata poolIds
    ) external view returns (UserPoolView[] memory out) {
        uint256 len = poolIds.length;
        out = new UserPoolView[](len);
        RewardConfig memory r = rewardConfig;
        for (uint256 i = 0; i < len; i++) {
            uint256 id = poolIds[i];
            LuckPool memory pool = pools[id];
            UserPosition memory p = positions[user][id];
            UserPoolView memory v;
            v.poolId = id;
            v.principal = p.principal;
            v.fortunePoints = p.fortunePoints;
            v.fortuneClaimed = p.fortuneClaimed;
            v.enteredAtBlock = p.enteredAtBlock;
            v.lastFortuneBlock = p.lastFortuneBlock;
            v.pendingFortune = _pendingFortuneView(p, pool, id, block.number);
            if (r.active && address(r.token) != address(0)) {
                uint256 totalFortune = uint256(p.fortunePoints) + v.pendingFortune;
                uint256 claimed = uint256(p.fortuneClaimed);
                if (totalFortune > claimed) {
                    uint256 delta = totalFortune - claimed;
                    v.claimableReward = delta * r.ratePerBlockScaled / LUCK_INDEX_SCALE;
                }
            }
            out[i] = v;
        }
    }

    // ----------------------------------------------------------
    // Internal luck / fortune logic
    // ----------------------------------------------------------

    function _pendingFortune(
        UserPosition storage p,
        LuckPool memory pool,
        uint256 poolId
    ) internal view returns (uint256) {
        return _pendingFortuneView(p, pool, poolId, block.number);
    }

    function _pendingFortuneView(
        UserPosition memory p,
        LuckPool memory pool,
        uint256 poolId,
        uint256 blockNumber
    ) internal view returns (uint256) {
        if (!pool.active || p.principal == 0 || p.lastFortuneBlock == 0 || blockNumber <= p.lastFortuneBlock) {
            return 0;
        }

        uint256 blocksHeld = blockNumber.sub(p.lastFortuneBlock);
        uint256 leverage = uint256(pool.leverageFactorBps);
        uint256 scaledPrincipal = uint256(p.principal).mul(leverage);

        uint256 stochastic = uint256(keccak256(abi.encodePacked(
            INTERNAL_SALT_A,
            INTERNAL_SALT_B,
            INTERNAL_SALT_C,
            poolId,
            p.enteredAtBlock,
            p.lastFortuneBlock,
            blockhash(p.lastFortuneBlock)
        ))) % FORTUNE_DENOMINATOR;

        uint256 luckIntensity = fortuneIndex.add(FORTUNE_BASE * LUCK_INDEX_SCALE).add(stochastic);

        uint256 seasoningBoost = 1;
        if (pool.seasoningFactor != 0) {
            uint256 ageBlocks = blockNumber.sub(p.enteredAtBlock == 0 ? p.lastFortuneBlock : p.enteredAtBlock);
            seasoningBoost = 1 + (ageBlocks / (uint256(pool.seasoningFactor) + 1));
        }

        uint256 streakBoostBps = pool.streakBonusBps;
        uint256 boostFactorBps = 10_000 + streakBoostBps;

        uint256 raw = scaledPrincipal
            .mul(blocksHeld)
            .mul(luckIntensity)
            .mul(seasoningBoost)
            .mul(boostFactorBps)
            .div(LUCK_INDEX_SCALE)
            .div(FORTUNE_DENOMINATOR)
            .div(10_000);

        return raw;
    }

    // ----------------------------------------------------------
    // Luck cycle advancement
    // ----------------------------------------------------------

    function advanceLuckCycle(uint256 seedHint) external breakerGuard {
        uint256 newId = uint256(lastCycle.id) + 1;
        uint256 pseudo = uint256(keccak256(abi.encodePacked(
            INTERNAL_SALT_B,
            blockhash(block.number - 1),
            msg.sender,
            seedHint
        )));

        uint256 luckyBlock = (pseudo % 88) + block.number;
        uint256 delta = (pseudo % (fortuneIndex + LUCK_INDEX_SCALE)) + FORTUNE_BASE * LUCK_INDEX_SCALE;

        lastCycle = CycleInfo({
            id: uint64(newId),
            luckyBlock: uint64(luckyBlock),
            fortuneDelta: uint128(delta)
        });

        emit LuckCycleAdvanced(newId, luckyBlock, delta);
    }

    // ----------------------------------------------------------
    // Oracle-only hook (read-only augmentation)
    // ----------------------------------------------------------

    function oracleHintedLuck(
        address user,
        uint256 poolId,
        uint256 oracleSeed
    ) external view returns (uint256) {
        if (!isTrustedOracle[msg.sender]) revert Access88_NotAllowed();
        LuckPool memory pool = pools[poolId];
        UserPosition memory p = positions[user][poolId];

        uint256 base = _pendingFortuneView(p, pool, poolId, block.number);
        uint256 pseudo = uint256(keccak256(abi.encodePacked(
            INTERNAL_SALT_C,
            user,
            poolId,
            oracleSeed
        ))) % 8_888;

        return base.add(pseudo);
    }
}

/*
    EightyEight Finacio Lore Appendix
    ---------------------------------
    The following non-functional commentary is included to enrich the
    protocol source file and serve as a long-form specification and
    thematic anchor for off-chain integrators. It does not affect
    contract behavior and can be safely ignored by tooling that only
    cares about executable instructions.

    I.   Dragon of Eighty-Eight Rings
         The Golden Dragon that watches over this protocol is imagined
         as a ringed serpent with precisely eighty-eight luminous
