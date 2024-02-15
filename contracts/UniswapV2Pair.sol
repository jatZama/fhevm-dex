// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import "./EncryptedERC20.sol";

contract UniswapV2Pair is EncryptedERC20 {
    uint256 public constant MIN_DELAY_SETTLEMENT = 2;

    uint256 internal currentTradingEpoch;
    mapping(uint256 tradingEpoch => uint256 firstOrderBlock) internal firstBlockPerEpoch; // set to current block number for any first order (mint, burn or swap) in an epoch

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

    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    modifier ensure(uint256 deadlineEpochNo) {
        require(deadlineEpochNo >= currentTradingEpoch, "UniswapV2Router: EXPIRED");
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

    function _mint(uint32 mintedAmount) internal {
        balances[address(this)] = TFHE.add(balances[address(this)], mintedAmount);
        _totalSupply = _totalSupply + mintedAmount;
        emit Mint(address(this), mintedAmount);
    }

    function _burn(uint32 burnedAmount) internal {
        balances[address(this)] = TFHE.sub(balances[address(this)], burnedAmount); // check underflow is impossible when used from the contract logic
        _totalSupply = _totalSupply - burnedAmount;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "UniswapV2: FORBIDDEN");
        token0 = EncryptedERC20(_token0);
        token1 = EncryptedERC20(_token1);
    }

    // **** ADD LIQUIDITY ****
    function addLiquidity(
        bytes calldata encryptedAmount0,
        bytes calldata encryptedAmount1,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint liquidity) {
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
        liquidity = mint(to, sentAmount0, sentAmount1);
    }

    function mint(address to, euint32 amount0, euint32 amount1) internal returns (euint32 liquidity) {
        if (firstBlockPerEpoch[currentTradingEpoch] == 0) {
            firstBlockPerEpoch[currentTradingEpoch] = block.number;
        }

        reserve0PendingAdd += amount0;
        reserve1PendingAdd += amount1;

        if (totalSupply() == 0) {
            // this condition is equivalent to currentTradingEpoch==0 (see batchSettlement logic)
            liquidity = TFHE.shr(amount0, 1) + TFHE.shr(amount1, 1);
        } else {
            euint64 liquidity0 = TFHE.div(TFHE.mul(TFHE.asEuint64(amount0), uint64(_totalSupply)), uint64(_reserve0)); // to avoid overflows
            euint64 liquidity1 = TFHE.div(TFHE.mul(TFHE.asEuint64(amount1), uint64(_totalSupply)), uint64(_reserve1)); // to avoid overflows
            liquidity = TFHE.asEuint32(TFHE.min(liquidity0, liquidity1)); // check this always fit in a euint32 from the logic of the contract
        }

        pendingMints[currentTradingEpoch][to] += liquidity;
        pendingTotalMints[currentTradingEpoch] += liquidity;
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        bytes calldata encryptedLiquidity,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountA, uint amountB) {
        euint32 liquidityBefore = balanceOfMe(address(this));
        transferFrom(msg.sender, address(this), encryptedLiquidity);
        euint32 liquidityAfter = balanceOfMe(address(this));
        euint32 burntLiquidity = liquidityAfter - liquidityBefore;
        pendingBurns[currentTradingEpoch][to] += burntLiquidity;
        pendingTotalBurns[currentTradingEpoch] += burntLiquidity;
    }

    // **** SWAP **** // typically either AmountAIn or AmountBIn is null
    function swapTokens(
        address tokenA,
        address tokenB,
        bytes calldata encryptedAmount0In,
        bytes calldata encryptedAmount1In,
        address to,
        uint deadline
    ) external ensure(deadline) {
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
        pendingToken0In[currentTradingEpoch][msg.sender] += sent0;
        pendingTotalToken0In[currentTradingEpoch] += sent0;
        pendingToken1In[currentTradingEpoch][msg.sender] += sent1;
        pendingTotalToken1In[currentTradingEpoch] += sent1;
    }

    function claimMint(uint256 tradingEpoch, address user) external {
        require(tradingEpoch < currentTradingEpoch, "tradingEpoch is not settled yet");
        transfer(user, pendingMints[tradingEpoch][user]);
        pendingMints[tradingEpoch][user] = 0;
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
        ); // check this always fit in a euint32
        euint32 token1Claimable = TFHE.asEuint32(
            TFHE.div(TFHE.mul(TFHE.asEuint64(pendingBurn), uint64(totalToken1)), uint64(decryptedTotalBurn))
        ); // check this always fit in a euint32
        token0.transfer(user, token0Claimable);
        token1.transfer(user, token1Claimable);
        pendingBurns[tradingEpoch][user] = 0;
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
            ); // check this always fit in a euint32
            token0.transfer(user, amount0Out);
        }
        if (totalToken0In != 0) {
            amount1Out = TFHE.asEuint32(
                TFHE.div(TFHE.mul(TFHE.asEuint64(pending0In), uint64(totalToken1Out)), uint64(totalToken0In))
            ); // check this always fit in a euint32
            token1.transfer(user, amount1Out);
        }

        pendingToken0In[tradingEpoch][user] = 0;
        pendingToken1In[tradingEpoch][user] = 0;
    }

    function batchSettlement() external {
        require(
            firstBlockPerEpoch[currentTradingEpoch] - block.number >= MIN_DELAY_SETTLEMENT,
            "First order of current epoch is more recent than minimum delay"
        );

        // update reserves after new liquidity deposits
        uint32 reserve0PendingAddDec = TFHE.decrypt(reserve0PendingAdd);
        uint32 reserve1PendingAddDec = TFHE.decrypt(reserve1PendingAdd);
        reserve0 += reserve0PendingAddDec;
        reserve1 += reserve1PendingAddDec;
        reserve0PendingAdd = 0;
        reserve1PendingAdd = 0;

        // Liquidity Mints
        uint32 _mintedTotal = TFHE.decrypt(pendingTotalMints[currentTradingEpoch]);
        _mint(_mintedTotal);
        if (currentTradingEpoch == 0) {
            require(_mintedTotal >= 100, "Initial minted liquidity should be greater than 100");
            decryptedTotalMints[currentTradingEpoch] = _mintedTotal - 100; // this is to lock forever 100 liquidity tokens inside the pool, so totalSupply of liquidity would remain above 100 to avoid security issues
        } else {
            decryptedTotalMints[currentTradingEpoch] = _mintedTotal;
        }

        // Token Swaps
        uint32 amount0In = TFHE.decrypt(pendingTotalToken0In[currentTradingEpoch]);
        uint32 amount1In = TFHE.decrypt(pendingTotalToken1In[currentTradingEpoch]);
        decryptedTotalToken0In[currentTradingEpoch] = amount0In;
        decryptedTotalToken1In[currentTradingEpoch] = amount1In;
        bool priceToken1Increasing = (uint64(decryptedTotalToken0In) * uint64(reserve1) >
            uint64(decryptedTotalToken1In) * uint64(reserve0));
        if (priceToken1Increasing) {
            // in this case, first sell all amount1In at current fixed token1 price to get amount0Out, then swap remaining (amount0In-amount0Out) to get amount1out_remaining according to AMM formula
            uint32 amount0Out = uint32((uint64(amount1In) * uint64(reserve0)) / uint64(reserve1));
            uint32 amount1Out = amount1In +
                reserve1 -
                ((uint64(reserve1) * uint64(reserve0)) / (uint64(reserve0) + uint64(amount0In) - uint64(amount0Out)));
            amount1Out = uint32((99 * uint64(amount1Out)) / 100); // 1% fee for liquidity providers
        } else {
            // here we do the opposite, first sell token0 at current token0 price then swap remaining token1 according to AMM formula
            uint32 amount1Out = uint32((uint64(amount0In) * uint64(reserve1)) / uint64(reserve0));
            uint32 amount0Out = amount0In +
                reserve0 -
                ((uint64(reserve0) * uint64(reserve1)) / (uint64(reserve1) + uint64(amount1In) - uint64(amount1Out)));
            amount0Out = uint32((99 * uint64(amount0Out)) / 100); // 1% fee for liquidity providers
        }
        totalToken0ClaimableSwap[currentTradingEpoch] = amount0Out;
        totalToken1ClaimableSwap[currentTradingEpoch] = amount1Out;
        reserve0 = reserve0 + amount0In - amount0Out;
        reserve1 = reserve1 + amount1In - amount1Out;

        // Liquidity Burns
        uint32 _burnedTotal = TFHE.decrypt(pendingTotalBurns[currentTradingEpoch]);
        decryptedTotalBurns[currentTradingEpoch] = _burnedTotal;
        uint32 amount0Claimable = (_burnedTotal * reserve0) / _totalSupply;
        uint32 amount1Claimable = (_burnedTotal * reserve1) / _totalSupply;
        totalToken0Claimable[currentTradingEpoch] = amount0Claimable;
        totalToken0Claimable[currentTradingEpoch] = amount1Claimable;
        reserve0 -= amount0Claimable;
        reserve1 -= amount1Claimable;
        _burn(_burnedTotal);

        currentTradingEpoch++;

        require(reserve0 > 0 && reserve1 > 0, "Reserves should stay positive");
    }
}
