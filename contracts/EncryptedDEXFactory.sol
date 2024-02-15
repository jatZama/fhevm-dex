// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import "./EncryptedDEXPair.sol";

contract EncryptedDEXFactory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    // tokenA and tokenB should be EncryptedERC20_32 contracts
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "EncryptedDEX: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "EncryptedDEX: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "EncryptedDEX: PAIR_EXISTS"); // single check is sufficient
        bytes32 _salt = keccak256(abi.encodePacked(token0, token1));
        pair = address(new EncryptedDEXPair{ salt: _salt }());
        EncryptedDEXPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
}
