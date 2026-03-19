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
