// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import "./EncryptedERC20.sol";

contract EncryptedDEXPair is EncryptedERC20 {
    struct DecryptionResults {
        uint32 reserve0PendingAddDec;
        uint32 reserve1PendingAddDec;
        uint32 mintedTotal;
        uint32 amount0In;
        uint32 amount1In;
        uint32 burnedTotal;
    }
    euint32 private ZERO = TFHE.asEuint32(0);
    uint32 public constant MINIMIMUM_LIQUIDITY = 100;
    uint256 public constant MIN_DELAY_SETTLEMENT = 2;

    uint256 public currentTradingEpoch;
    mapping(uint256 tradingEpoch => uint256 firstOrderBlock) internal firstBlockPerEpoch;
    // set to current block number for any first order (mint, burn or swap) in an epoch

    mapping(uint256 tradingEpoch => mapping(address user => euint32 mintedLiquidity)) internal pendingMints;
    mapping(uint256 tradingEpoch => euint32 mintedTotalLiquidity) internal pendingTotalMints;
    mapping(uint256 tradingEpoch => uint32 mintedTotalLiquidity) internal decryptedTotalMints;

    mapping(uint256 tradingEpoch => mapping(address user => euint32 burnedLiquidity)) internal pendingBurns;
    mapping(uint256 tradingEpoch => euint32 burnedTotalLiquidity) internal pendingTotalBurns;
    mapping(uint256 tradingEpoch => uint32 burnedTotalLiquidity) internal decryptedTotalBurns;
    mapping(uint256 tradingEpoch => uint32 totalToken0) internal totalToken0ClaimableBurn;
    mapping(uint256 tradingEpoch => uint32 totalToken1) internal totalToken1ClaimableBurn;

    mapping(uint256 tradingEpoch => mapping(address user => euint32 swappedToken0In)) internal pendingToken0In;
    mapping(uint256 tradingEpoch => euint32 swappedTotalToken0In) internal pendingTotalToken0In;
    mapping(uint256 tradingEpoch => uint32 swappedTotalToken0In) internal decryptedTotalToken0In;
    mapping(uint256 tradingEpoch => mapping(address user => euint32 swappedToken1In)) internal pendingToken1In;
    mapping(uint256 tradingEpoch => euint32 swappedTotalToken1In) internal pendingTotalToken1In;
    mapping(uint256 tradingEpoch => uint32 swappedTotalToken1In) internal decryptedTotalToken1In;
    mapping(uint256 tradingEpoch => uint32 totalToken0) internal totalToken0ClaimableSwap;
    mapping(uint256 tradingEpoch => uint32 totalToken1) internal totalToken1ClaimableSwap;

    address public factory;
    EncryptedERC20 public token0;
    EncryptedERC20 public token1;

    uint32 private reserve0;
    uint32 private reserve1;

    euint32 private reserve0PendingAdd;
    euint32 private reserve1PendingAdd;

    uint256 private unlocked = 1;

    event Burn(uint256 burnedAmount);

    modifier lock() {
        require(unlocked == 1, "EncryptedDEX: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    modifier ensure(uint256 deadlineEpochNo) {
        require(deadlineEpochNo >= currentTradingEpoch, "EncryptedDEXRouter: EXPIRED");
        _;
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    function getReserves() public view returns (uint32 _reserve0, uint32 _reserve1) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
    }

    constructor() EncryptedERC20("Liquidity Token", "PAIR") {
        factory = msg.sender;
    }

    function _mintPartial(uint32 mintedAmount) internal {
        // this is a partial mint, balances are updated later during the claim
        _totalSupply = _totalSupply + mintedAmount;
        emit Mint(address(this), mintedAmount);
    }

    function _burn(uint32 burnedAmount) internal {
        balances[address(this)] = TFHE.sub(balances[address(this)], burnedAmount); // underflow is impossible when used from the contract logic
        _totalSupply = _totalSupply - burnedAmount;
        emit Burn(burnedAmount);
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "EncryptedDEX: FORBIDDEN");
        token0 = EncryptedERC20(_token0);
        token1 = EncryptedERC20(_token1);
    }

    // **** ADD LIQUIDITY ****
    function addLiquidity(
        bytes calldata encryptedAmount0,
        bytes calldata encryptedAmount1,
        address to,
        uint256 deadline
    ) external ensure(deadline) {
        euint32 balance0Before = token0.balanceOfMe();
        euint32 balance1Before = token1.balanceOfMe();
        euint32 amount0 = TFHE.asEuint32(encryptedAmount0);
        euint32 amount1 = TFHE.asEuint32(encryptedAmount1);
        token0.transferFrom(msg.sender, address(this), amount0);
        token1.transferFrom(msg.sender, address(this), amount1);
        euint32 balance0After = token0.balanceOfMe();
        euint32 balance1After = token1.balanceOfMe();
        euint32 sentAmount0 = balance0After - balance0Before;
        euint32 sentAmount1 = balance1After - balance1Before;
        mint(to, sentAmount0, sentAmount1);
    }

    function mint(address to, euint32 amount0, euint32 amount1) internal {
        uint256 currentEpoch = currentTradingEpoch;
        if (firstBlockPerEpoch[currentEpoch] == 0) {
            firstBlockPerEpoch[currentEpoch] = block.number;
        }
        reserve0PendingAdd = reserve0PendingAdd + amount0;
        reserve1PendingAdd = reserve1PendingAdd + amount1;
        euint32 liquidity;
        if (totalSupply() == 0) {
            // this condition is equivalent to currentEpoch==0 (see batchSettlement logic)
            liquidity = TFHE.shr(amount0, 1) + TFHE.shr(amount1, 1);
            ebool isBelowMinimum = TFHE.lt(liquidity, MINIMIMUM_LIQUIDITY);
            liquidity = TFHE.cmux(isBelowMinimum, ZERO, liquidity);
            euint32 amount0Back = TFHE.cmux(isBelowMinimum, amount0, ZERO);
            euint32 amount1Back = TFHE.cmux(isBelowMinimum, amount1, ZERO);
            token0.transfer(msg.sender, amount0Back); // refund first liquidity if it is below the minimal amount
            token1.transfer(msg.sender, amount1Back); // refund first liquidity if it is below the minimal amount
            reserve0PendingAdd = reserve0PendingAdd - amount0Back;
            reserve1PendingAdd = reserve1PendingAdd - amount1Back;
        } else {
            euint64 liquidity0 = TFHE.div(TFHE.mul(TFHE.asEuint64(amount0), uint64(_totalSupply)), uint64(reserve0)); // to avoid overflows
            euint64 liquidity1 = TFHE.div(TFHE.mul(TFHE.asEuint64(amount1), uint64(_totalSupply)), uint64(reserve1)); // to avoid overflows
            liquidity = TFHE.asEuint32(TFHE.min(liquidity0, liquidity1)); // this always fit in a euint32 from the logic of the contract
        }
        pendingMints[currentEpoch][to] = pendingMints[currentEpoch][to] + liquidity;
        pendingTotalMints[currentEpoch] = pendingTotalMints[currentEpoch] + liquidity;
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(bytes calldata encryptedLiquidity, address to, uint256 deadline) public ensure(deadline) {
        uint256 currentEpoch = currentTradingEpoch;
        if (firstBlockPerEpoch[currentEpoch] == 0) {
            firstBlockPerEpoch[currentEpoch] = block.number;
        }
        euint32 liquidityBefore = balances[address(this)];
        transfer(address(this), TFHE.asEuint32(encryptedLiquidity));
        euint32 liquidityAfter = balances[address(this)];
        euint32 burntLiquidity = liquidityAfter - liquidityBefore;
        pendingBurns[currentEpoch][to] = pendingBurns[currentEpoch][to] + burntLiquidity;
        pendingTotalBurns[currentEpoch] = pendingTotalBurns[currentEpoch] + burntLiquidity;
    }

    // **** SWAP **** // typically either Amount0In or Amount1In is null
    function swapTokens(
        bytes calldata encryptedAmount0In,
        bytes calldata encryptedAmount1In,
        address to,
        uint256 deadline
    ) external ensure(deadline) {
        uint256 currentEpoch = currentTradingEpoch;
        if (firstBlockPerEpoch[currentEpoch] == 0) {
            firstBlockPerEpoch[currentEpoch] = block.number;
        }
        euint32 balance0Before = token0.balanceOfMe();
        euint32 balance1Before = token1.balanceOfMe();
        euint32 amount0In = TFHE.asEuint32(encryptedAmount0In); // even if amount is null, do a transfer to obfuscate trade direction
        euint32 amount1In = TFHE.asEuint32(encryptedAmount1In); // even if amount is null, do a transfer to obfuscate trade direction
        token0.transferFrom(msg.sender, address(this), amount0In);
        token1.transferFrom(msg.sender, address(this), amount1In);
        euint32 balance0After = token0.balanceOfMe();
        euint32 balance1After = token1.balanceOfMe();
        euint32 sent0 = balance0After - balance0Before;
        euint32 sent1 = balance1After - balance1Before;
        pendingToken0In[currentEpoch][to] = pendingToken0In[currentEpoch][to] + sent0;
        pendingTotalToken0In[currentEpoch] = pendingTotalToken0In[currentEpoch] + sent0;
        pendingToken1In[currentEpoch][to] = pendingToken1In[currentEpoch][to] + sent1;
        pendingTotalToken1In[currentEpoch] = pendingTotalToken1In[currentEpoch] + sent1;
    }

    function claimMint(uint256 tradingEpoch, address user) external {
        require(tradingEpoch < currentTradingEpoch, "tradingEpoch is not settled yet");
        _mint(tradingEpoch, user);
        pendingMints[tradingEpoch][user] = ZERO;
    }

    function _mint(uint256 tradingEpoch, address user) internal {
        if (tradingEpoch == 0) {
            balances[user] = TFHE.sub(balances[user] + pendingMints[tradingEpoch][user], MINIMIMUM_LIQUIDITY); // this could never underflow from the contract logic
        } else {
            balances[user] = balances[user] + pendingMints[tradingEpoch][user];
        }
    }

    function claimBurn(uint256 tradingEpoch, address user) external {
        require(tradingEpoch < currentTradingEpoch, "tradingEpoch is not settled yet");
        euint32 pendingBurn = pendingBurns[tradingEpoch][user];
        uint32 decryptedTotalBurn = decryptedTotalBurns[tradingEpoch];
        require(decryptedTotalBurn != 0, "No liquidity was burnt during tradingEpoch");
        uint32 totalToken0 = totalToken0ClaimableBurn[tradingEpoch];
        uint32 totalToken1 = totalToken1ClaimableBurn[tradingEpoch];
        euint32 token0Claimable = TFHE.asEuint32(
            TFHE.div(TFHE.mul(TFHE.asEuint64(pendingBurn), uint64(totalToken0)), uint64(decryptedTotalBurn))
        ); // this always fit in a euint32
        euint32 token1Claimable = TFHE.asEuint32(
            TFHE.div(TFHE.mul(TFHE.asEuint64(pendingBurn), uint64(totalToken1)), uint64(decryptedTotalBurn))
        ); // this always fit in a euint32
        token0.transfer(user, token0Claimable);
        token1.transfer(user, token1Claimable);
        pendingBurns[tradingEpoch][user] = ZERO;
    }

    function claimSwap(uint256 tradingEpoch, address user) external {
        require(tradingEpoch < currentTradingEpoch, "tradingEpoch is not settled yet");
        euint32 pending0In = pendingToken0In[tradingEpoch][user];
        uint32 totalToken0In = decryptedTotalToken0In[tradingEpoch];
        euint32 pending1In = pendingToken1In[tradingEpoch][user];
        uint32 totalToken1In = decryptedTotalToken1In[tradingEpoch];

        uint32 totalToken0Out = totalToken0ClaimableSwap[tradingEpoch];
        uint32 totalToken1Out = totalToken1ClaimableSwap[tradingEpoch];

        euint32 amount0Out;
        euint32 amount1Out;

        if (totalToken1In != 0) {
            amount0Out = TFHE.asEuint32(
                TFHE.div(TFHE.mul(TFHE.asEuint64(pending1In), uint64(totalToken0Out)), uint64(totalToken1In))
            ); // this always fit in a euint32
            token0.transfer(user, amount0Out);
        }
        if (totalToken0In != 0) {
            amount1Out = TFHE.asEuint32(
                TFHE.div(TFHE.mul(TFHE.asEuint64(pending0In), uint64(totalToken1Out)), uint64(totalToken0In))
            ); // this always fit in a euint32
            token1.transfer(user, amount1Out);
        }

        pendingToken0In[tradingEpoch][user] = ZERO;
        pendingToken1In[tradingEpoch][user] = ZERO;
    }

    function requestAllDecryptions() internal view returns (DecryptionResults memory) {
        uint32 reserve0PendingAddDec;
        uint32 reserve1PendingAddDec;
        uint32 mintedTotal;
        uint32 amount0In;
        uint32 amount1In;
        uint32 burnedTotal;
        if (TFHE.isInitialized(reserve0PendingAdd)) reserve0PendingAddDec = TFHE.decrypt(reserve0PendingAdd);
        if (TFHE.isInitialized(reserve1PendingAdd)) reserve1PendingAddDec = TFHE.decrypt(reserve1PendingAdd);
        if (TFHE.isInitialized(pendingTotalMints[currentTradingEpoch]))
            mintedTotal = TFHE.decrypt(pendingTotalMints[currentTradingEpoch]);
        if (TFHE.isInitialized(pendingTotalToken0In[currentTradingEpoch]))
            amount0In = TFHE.decrypt(pendingTotalToken0In[currentTradingEpoch]);
        if (TFHE.isInitialized(pendingTotalToken1In[currentTradingEpoch]))
            amount1In = TFHE.decrypt(pendingTotalToken1In[currentTradingEpoch]);
        if (TFHE.isInitialized(pendingTotalBurns[currentTradingEpoch]))
            burnedTotal = TFHE.decrypt(pendingTotalBurns[currentTradingEpoch]);
        return
            DecryptionResults(
                reserve0PendingAddDec,
                reserve1PendingAddDec,
                mintedTotal,
                amount0In,
                amount1In,
                burnedTotal
            );
    }

    function batchSettlement() external {
        uint256 tradingEpoch = currentTradingEpoch;
        require(firstBlockPerEpoch[tradingEpoch] != 0, "Current trading epoch did not start yet");
        require(
            block.number - firstBlockPerEpoch[tradingEpoch] >= MIN_DELAY_SETTLEMENT,
            "First order of current epoch is more recent than minimum delay"
        );
        // get all needed decryptions in a single call (this pattern is helpful to later adapt the design when TFHE.decrypt wil become asynchronous)
        DecryptionResults memory decResults = requestAllDecryptions();

        // update reserves after new liquidity deposits
        reserve0 += decResults.reserve0PendingAddDec;
        reserve1 += decResults.reserve1PendingAddDec;
        reserve0PendingAdd = ZERO;
        reserve1PendingAdd = ZERO;

        // Liquidity Mints
        require(
            tradingEpoch != 0 || decResults.mintedTotal >= MINIMIMUM_LIQUIDITY,
            "Initial minted liquidity amount should be greater than MINIMIMUM_LIQUIDITY"
        );
        // this is to lock forever at least MINIMIMUM_LIQUIDITY liquidity tokens inside the pool, so totalSupply of liquidity would remain above
        // MINIMIMUM_LIQUIDITY to avoid security issues, for e.g. if a market maker burns the entire liquidity in a single transaction, making the pool unusable
        if (decResults.mintedTotal > 0) {
            _mintPartial(decResults.mintedTotal);
            decryptedTotalMints[tradingEpoch] = decResults.mintedTotal;
        }

        // Token Swaps
        decryptedTotalToken0In[tradingEpoch] = decResults.amount0In;
        decryptedTotalToken1In[tradingEpoch] = decResults.amount1In;
        uint32 amount0InMinusFee = uint32((99 * uint64(decResults.amount0In)) / 100); // 1% fee for liquidity providers
        uint32 amount1InMinusFee = uint32((99 * uint64(decResults.amount1In)) / 100); // 1% fee for liquidity providers
        bool priceToken1Increasing = (uint64(decResults.amount0In) * uint64(reserve1) >
            uint64(decResults.amount1In) * uint64(reserve0));
        uint32 amount0Out;
        uint32 amount1Out;
        if (priceToken1Increasing) {
            // in this case, first sell all amount1In at current fixed token1 price to get amount0Out, then swap remaining (amount0In-amount0Out)
            // to get amount1out_remaining according to AMM formula
            amount0Out = uint32((uint64(amount1InMinusFee) * uint64(reserve0)) / uint64(reserve1));
            // NOTE : reserve1 should never be 0 after first liquidity minting event -see assert at the end- if first batchSettlement
            //  is called without minting, tx will fail anyways
            amount1Out =
                amount1InMinusFee +
                reserve1 -
                uint32(
                    (uint64(reserve1) * uint64(reserve0)) /
                        (uint64(reserve0) + uint64(amount0InMinusFee) - uint64(amount0Out))
                );
        } else {
            // here we do the opposite, first sell token0 at current token0 price then swap remaining token1 according to AMM formula
            amount1Out = uint32((uint64(amount0InMinusFee) * uint64(reserve1)) / uint64(reserve0));
            // NOTE : reserve0 should never be 0 after first liquidity minting event -see assert at the end- if first batchSettlement
            // is called without minting, tx will fail anyways
            amount0Out =
                amount0InMinusFee +
                reserve0 -
                uint32(
                    (uint64(reserve0) * uint64(reserve1)) /
                        (uint64(reserve1) + uint64(amount1InMinusFee) - uint64(amount1Out))
                );
        }
        totalToken0ClaimableSwap[tradingEpoch] = amount0Out;
        totalToken1ClaimableSwap[tradingEpoch] = amount1Out;
        reserve0 = reserve0 + decResults.amount0In - amount0Out;
        reserve1 = reserve1 + decResults.amount1In - amount1Out;

        // Liquidity Burns
        if (decResults.burnedTotal > 0) {
            decryptedTotalBurns[tradingEpoch] = decResults.burnedTotal;
            uint32 amount0Claimable = uint32(
                (uint64(decResults.burnedTotal) * uint64(reserve0)) / uint64(_totalSupply)
            );
            uint32 amount1Claimable = uint32(
                (uint64(decResults.burnedTotal) * uint64(reserve1)) / uint64(_totalSupply)
            );
            totalToken0ClaimableBurn[tradingEpoch] = amount0Claimable;
            totalToken1ClaimableBurn[tradingEpoch] = amount1Claimable;
            reserve0 -= amount0Claimable;
            reserve1 -= amount1Claimable;
            _burn(decResults.burnedTotal);
        }

        currentTradingEpoch++;

        assert(reserve0 > 0 && reserve1 > 0); // Reserves should stay positive
    }
}
