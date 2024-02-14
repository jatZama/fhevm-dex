// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Token is ERC20, Ownable {
    constructor(string memory name, string memory symbol)
        ERC20(name, symbol) Ownable(msg.sender){}

    function mint(address to, uint256 amount) public onlyOwner() {
        _mint(to, amount);
    }
}