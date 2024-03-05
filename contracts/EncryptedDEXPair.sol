// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import "./EncryptedERC20.sol";

contract EncryptedDEXPair is EncryptedERC20 {
    struct DecryptionResults {
        uint64 reserve0PendingAddDec;
        uint64 reserve1PendingAddDec;
        uint64 mintedTotal;
        uint64 amount0In;
        uint64 amount1In;
        uint64 burnedTotal;
    }
    euint64 private ZERO = TFHE.asEuint64(0);
    uint64 public constant MINIMIMUM_LIQUIDITY = 100 * 2 ** 32;
    uint256 public constant MIN_DELAY_SETTLEMENT = 2;

    uint256 public currentTradingEpoch;
    mapping(uint256 tradingEpoch => uint256 firstOrderBlock) internal firstBlockPerEpoch; // set to current block number for any first order (mint, burn or swap) in an epoch

    mapping(uint256 tradingEpoch => mapping(address user => euint64 mintedLiquidity)) internal pendingMints;
    mapping(uint256 tradingEpoch => euint64 mintedTotalLiquidity) internal pendingTotalMints;
    mapping(uint256 tradingEpoch => uint64 mintedTotalLiquidity) internal decryptedTotalMints;

    mapping(uint256 tradingEpoch => mapping(address user => euint64 burnedLiquidity)) internal pendingBurns;
    mapping(uint256 tradingEpoch => euint64 burnedTotalLiquidity) internal pendingTotalBurns;
    mapping(uint256 tradingEpoch => uint64 burnedTotalLiquidity) internal decryptedTotalBurns;
    mapping(uint256 tradingEpoch => uint64 totalToken0) internal totalToken0ClaimableBurn;
    mapping(uint256 tradingEpoch => uint64 totalToken1) internal totalToken1ClaimableBurn;

    mapping(uint256 tradingEpoch => mapping(address user => euint64 swappedToken0In)) internal pendingToken0In;
    mapping(uint256 tradingEpoch => euint64 swappedTotalToken0In) internal pendingTotalToken0In;
    mapping(uint256 tradingEpoch => uint64 swappedTotalToken0In) internal decryptedTotalToken0In;
    mapping(uint256 tradingEpoch => mapping(address user => euint64 swappedToken1In)) internal pendingToken1In;
    mapping(uint256 tradingEpoch => euint64 swappedTotalToken1In) internal pendingTotalToken1In;
    mapping(uint256 tradingEpoch => uint64 swappedTotalToken1In) internal decryptedTotalToken1In;
    mapping(uint256 tradingEpoch => uint64 totalToken0) internal totalToken0ClaimableSwap;
    mapping(uint256 tradingEpoch => uint64 totalToken1) internal totalToken1ClaimableSwap;

    address public factory;
    EncryptedERC20 public token0;
    EncryptedERC20 public token1;

    uint64 private reserve0;
    uint64 private reserve1;

    euint64 private reserve0PendingAdd;
    euint64 private reserve1PendingAdd;

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

    function getReserves() public view returns (uint64 _reserve0, uint64 _reserve1) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
    }

    constructor() EncryptedERC20("Liquidity Token", "PAIR") {
        factory = msg.sender;
    }

    function _mintPartial(uint64 mintedAmount) internal {
        // this is a partial mint, balances are updated later during the claim
        _totalSupply = _totalSupply + mintedAmount;
        emit Mint(address(this), mintedAmount);
    }

    function _burn(uint64 burnedAmount) internal {
        balances[address(this)] = TFHE.sub(balances[address(this)], burnedAmount); // check underflow is impossible when used from the contract logic
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
        euint64 balance0Before = token0.balanceOfMe();
        euint64 balance1Before = token1.balanceOfMe();
        euint64 amount0 = TFHE.shl(TFHE.shr(TFHE.asEuint64(encryptedAmount0), 32), 32);
        euint64 amount1 = TFHE.shl(TFHE.shr(TFHE.asEuint64(encryptedAmount1), 32), 32);
        token0.transferFrom(msg.sender, address(this), amount0);
        token1.transferFrom(msg.sender, address(this), amount1);
        euint64 balance0After = token0.balanceOfMe();
        euint64 balance1After = token1.balanceOfMe();
        euint64 sentAmount0 = balance0After - balance0Before;
        euint64 sentAmount1 = balance1After - balance1Before;
        mint(to, sentAmount0, sentAmount1);
    }

    function mint(address to, euint64 amount0, euint64 amount1) internal {
        uint256 currentEpoch = currentTradingEpoch;
        if (firstBlockPerEpoch[currentEpoch] == 0) {
            firstBlockPerEpoch[currentEpoch] = block.number;
        }
        reserve0PendingAdd = reserve0PendingAdd + amount0;
        reserve1PendingAdd = reserve1PendingAdd + amount1;
        euint64 liquidity;
        if (totalSupply() == 0) {
            // this condition is equivalent to currentEpoch==0 (see batchSettlement logic)
            liquidity = TFHE.shr(amount0, 1) + TFHE.shr(amount1, 1);
            ebool isBelowMinimum = TFHE.lt(liquidity, MINIMIMUM_LIQUIDITY);
            liquidity = TFHE.cmux(isBelowMinimum, ZERO, liquidity);
            euint64 amount0Back = TFHE.cmux(isBelowMinimum, amount0, ZERO);
            euint64 amount1Back = TFHE.cmux(isBelowMinimum, amount1, ZERO);
            token0.transfer(msg.sender, amount0Back); // refund first liquidity if it is below the minimal amount
            token1.transfer(msg.sender, amount1Back); // refund first liquidity if it is below the minimal amount
            reserve0PendingAdd = reserve0PendingAdd - amount0Back;
            reserve1PendingAdd = reserve1PendingAdd - amount1Back;
        } else {
            euint64 liquidity0 = TFHE.div(TFHE.mul(TFHE.shr(amount0, 32), _totalSupply >> 32), reserve0 >> 32);
            euint64 liquidity1 = TFHE.div(TFHE.mul(TFHE.shr(amount1, 32), _totalSupply >> 32), reserve1 >> 32);
            liquidity = TFHE.shl(TFHE.min(liquidity0, liquidity1), 32);
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
        euint64 liquidityBefore = balances[address(this)];
        transfer(address(this), TFHE.shl(TFHE.shr(TFHE.asEuint64(encryptedLiquidity), 32), 32)); // only allow removing multiple of 2**32 to keep total supply a multiple of 2**32
        euint64 liquidityAfter = balances[address(this)];
        euint64 burntLiquidity = liquidityAfter - liquidityBefore;
        pendingBurns[currentEpoch][to] = pendingBurns[currentEpoch][to] + burntLiquidity;
        pendingTotalBurns[currentEpoch] = pendingTotalBurns[currentEpoch] + burntLiquidity;
    }

    // **** SWAP **** // typically either AmountAIn or AmountBIn is null
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
        euint64 balance0Before = token0.balanceOfMe();
        euint64 balance1Before = token1.balanceOfMe();
        euint64 amount0In = TFHE.shl(TFHE.shr(TFHE.asEuint64(encryptedAmount0In), 32), 32); // even if amount is null, do a transfer to obfuscate trade direction
        euint64 amount1In = TFHE.shl(TFHE.shr(TFHE.asEuint64(encryptedAmount1In), 32), 32); // even if amount is null, do a transfer to obfuscate trade direction
        token0.transferFrom(msg.sender, address(this), amount0In);
        token1.transferFrom(msg.sender, address(this), amount1In);
        euint64 balance0After = token0.balanceOfMe();
        euint64 balance1After = token1.balanceOfMe();
        euint64 sent0 = balance0After - balance0Before;
        euint64 sent1 = balance1After - balance1Before;
        pendingToken0In[currentEpoch][to] = pendingToken0In[currentEpoch][to] + sent0;
        pendingTotalToken0In[currentEpoch] = pendingTotalToken0In[currentEpoch] + sent0;
        pendingToken1In[currentEpoch][to] = pendingToken1In[currentEpoch][to] + sent1;
        pendingTotalToken1In[currentEpoch] = pendingTotalToken1In[currentEpoch] + sent1;
    }

    function claimMint(uint256 tradingEpoch, address user) external {
        require(tradingEpoch < currentTradingEpoch, "tradingEpoch is not settled yet");
        if (tradingEpoch == 0) {
            balances[user] = TFHE.sub(balances[user] + pendingMints[tradingEpoch][user], MINIMIMUM_LIQUIDITY); // this could fail in the very theoretical case where several market makers would mint individually
            //  less than MINIMIMUM_LIQUIDITY LP tokens but their sum is above MINIMIMUM_LIQUIDITY. NOT a vulnerability, as long as the first market makers are aware that the avarage sent amounts during first tradingEpoch must be above MINIMIMUM_LIQUIDITY.
        } else {
            balances[user] = balances[user] + pendingMints[tradingEpoch][user];
        }
        pendingMints[tradingEpoch][user] = ZERO;
    }

    function claimBurn(uint256 tradingEpoch, address user) external {
        require(tradingEpoch < currentTradingEpoch, "tradingEpoch is not settled yet");
        euint64 pendingBurn = pendingBurns[tradingEpoch][user];
        uint64 decryptedTotalBurn = decryptedTotalBurns[tradingEpoch];
        require(decryptedTotalBurn != 0, "No liquidity was burnt during tradingEpoch");
        uint64 totalToken0 = totalToken0ClaimableBurn[tradingEpoch];
        uint64 totalToken1 = totalToken1ClaimableBurn[tradingEpoch];
        euint64 token0Claimable = TFHE.shl(
            TFHE.div(TFHE.mul(TFHE.shr(pendingBurn, 32), totalToken0 >> 32), decryptedTotalBurn >> 32),
            32
        );
        euint64 token1Claimable = TFHE.shl(
            TFHE.div(TFHE.mul(TFHE.shr(pendingBurn, 32), totalToken1 >> 32), decryptedTotalBurn >> 32),
            32
        );
        token0.transfer(user, token0Claimable);
        token1.transfer(user, token1Claimable);
        pendingBurns[tradingEpoch][user] = ZERO;
    }

    function claimSwap(uint256 tradingEpoch, address user) external {
        require(tradingEpoch < currentTradingEpoch, "tradingEpoch is not settled yet");
        euint64 pending0In = pendingToken0In[tradingEpoch][user];
        uint64 totalToken0In = decryptedTotalToken0In[tradingEpoch];
        euint64 pending1In = pendingToken1In[tradingEpoch][user];
        uint64 totalToken1In = decryptedTotalToken1In[tradingEpoch];

        uint64 totalToken0Out = totalToken0ClaimableSwap[tradingEpoch];
        uint64 totalToken1Out = totalToken1ClaimableSwap[tradingEpoch];

        euint64 amount0Out;
        euint64 amount1Out;

        if (totalToken1In != 0) {
            amount0Out = TFHE.shl(
                TFHE.div(TFHE.mul(TFHE.shr(pending1In, 32), totalToken0Out >> 32), totalToken1In >> 32),
                32
            );
            token0.transfer(user, amount0Out);
        }
        if (totalToken0In != 0) {
            amount1Out = TFHE.shl(
                TFHE.div(TFHE.mul(TFHE.shr(pending0In, 32), totalToken1Out >> 32), totalToken0In >> 32),
                32
            );
            token1.transfer(user, amount1Out);
        }

        pendingToken0In[tradingEpoch][user] = ZERO;
        pendingToken1In[tradingEpoch][user] = ZERO;
    }

    function requestAllDecryptions() internal view returns (DecryptionResults memory) {
        uint64 reserve0PendingAddDec;
        uint64 reserve1PendingAddDec;
        uint64 mintedTotal;
        uint64 amount0In;
        uint64 amount1In;
        uint64 burnedTotal;
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
        ); // this is to lock forever at least MINIMIMUM_LIQUIDITY liquidity tokens inside the pool, so totalSupply of liquidity
        // would remain above MINIMIMUM_LIQUIDITY to avoid security issues,  for instance if a single market maker wants to burn the whole liquidity in a single transaction, making the pool unusable
        if (decResults.mintedTotal > 0) {
            _mintPartial(decResults.mintedTotal);
            decryptedTotalMints[tradingEpoch] = decResults.mintedTotal;
        }

        // Token Swaps
        decryptedTotalToken0In[tradingEpoch] = decResults.amount0In;
        decryptedTotalToken1In[tradingEpoch] = decResults.amount1In;
        uint64 amount0InMinusFee = ((99 * (decResults.amount0In >> 32)) / 100) << 32; // 1% fee for liquidity providers
        uint64 amount1InMinusFee = ((99 * (decResults.amount1In >> 32)) / 100) << 32; // 1% fee for liquidity providers
        bool priceToken1Increasing = (uint128(decResults.amount0In) * uint128(reserve1) >
            uint128(decResults.amount1In) * uint128(reserve0));
        uint64 amount0Out;
        uint64 amount1Out;
        if (priceToken1Increasing) {
            // in this case, first sell all amount1In at current fixed token1 price to get amount0Out, then swap remaining (amount0In-amount0Out) to get amount1out_remaining according to AMM formula
            amount0Out = (((amount1InMinusFee >> 32) * (reserve0 >> 32)) / (reserve1 >> 32)) << 32;
            amount1Out =
                amount1InMinusFee +
                reserve1 -
                ((((reserve1 >> 32) * (reserve0 >> 32)) /
                    ((reserve0 >> 32) + (amount0InMinusFee >> 32) - (amount0Out >> 32))) << 32);
        } else {
            // here we do the opposite, first sell token0 at current token0 price then swap remaining token1 according to AMM formula
            amount1Out = (((amount0InMinusFee >> 32) * (reserve1 >> 32)) / (reserve0 >> 32)) << 32;
            amount0Out =
                amount0InMinusFee +
                reserve0 -
                ((((reserve0 >> 32) * (reserve1 >> 32)) /
                    ((reserve1 >> 32) + (amount1InMinusFee >> 32) - (amount1Out >> 32))) << 32);
        }
        totalToken0ClaimableSwap[tradingEpoch] = amount0Out;
        totalToken1ClaimableSwap[tradingEpoch] = amount1Out;
        reserve0 = reserve0 + decResults.amount0In - amount0Out;
        reserve1 = reserve1 + decResults.amount1In - amount1Out;

        // Liquidity Burns
        if (decResults.burnedTotal > 0) {
            decryptedTotalBurns[tradingEpoch] = decResults.burnedTotal;
            uint64 amount0Claimable = (((decResults.burnedTotal >> 32) * (reserve0 >> 32)) / (_totalSupply >> 32)) <<
                32;
            uint64 amount1Claimable = (((decResults.burnedTotal >> 32) * (reserve1 >> 32)) / (_totalSupply >> 32)) <<
                32;
            totalToken0ClaimableBurn[tradingEpoch] = amount0Claimable;
            totalToken1ClaimableBurn[tradingEpoch] = amount1Claimable;
            reserve0 -= amount0Claimable;
            reserve1 -= amount1Claimable;
            _burn(decResults.burnedTotal);
        }

        currentTradingEpoch++;

        require(reserve0 > 0 && reserve1 > 0, "Reserves should stay positive");
    }
}
