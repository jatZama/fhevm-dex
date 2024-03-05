import { expect } from "chai";
import { ethers } from "hardhat";

import { createInstances } from "../instance";
import { getSigners, initSigners } from "../signers";
import { deployEncryptedDEXFactoryFixture } from "./EncryptedDEXFactory.fixture";
import { deployEncryptedERC20Fixture, getPrivateBalanceERC20 } from "./EncryptedERC20.fixture";

describe("Private DEX", function () {
  before(async function () {
    await initSigners();
    this.signers = await getSigners();
  });

  it("Encrypted DEX Pool - multiple epochs", async function () {
    const COIN = 2n ** 32n;
    let token0 = await deployEncryptedERC20Fixture();
    let token0Address = await token0.getAddress();
    let token1 = await deployEncryptedERC20Fixture();
    let token1Address = await token1.getAddress();

    BigInt(token0Address) > BigInt(token1Address) ? ([token0, token1] = [token1, token0]) : null; // sort tokens according to addresses
    token0Address = await token0.getAddress();
    token1Address = await token1.getAddress();

    const tx0 = await token0.mint(2_000_000_000n * COIN);
    await tx0.wait();
    const instances0 = await createInstances(token0Address, ethers, this.signers);
    const tx1 = await token1.mint(2_000_000_000n * COIN);
    await tx1.wait();
    const instances1 = await createInstances(token1Address, ethers, this.signers);
    let balance = await getPrivateBalanceERC20(token0Address, "alice");
    expect(balance).to.equal(2_000_000_000n * COIN);
    const totalSupply = await token0.totalSupply();
    expect(totalSupply).to.equal(2_000_000_000n * COIN);

    const tx2 = await token0["transfer(address,bytes)"](
      this.signers.bob.address,
      instances0.alice.encrypt64(100_000_000n * COIN),
    );
    await tx2.wait();

    balance = await getPrivateBalanceERC20(token0Address, "alice");
    expect(balance).to.equal(1_900_000_000n * COIN);
    balance = await getPrivateBalanceERC20(token0Address, "bob");
    expect(balance).to.equal(100_000_000n * COIN);

    const tx3 = await token0["transfer(address,bytes)"](
      this.signers.carol.address,
      instances0.alice.encrypt64(200_000_000n * COIN),
    );
    await tx3.wait();

    const tx4 = await token1["transfer(address,bytes)"](
      this.signers.bob.address,
      instances1.alice.encrypt64(200_000_000n * COIN),
    );
    await tx4.wait();

    const tx5 = await token1["transfer(address,bytes)"](
      this.signers.carol.address,
      instances1.alice.encrypt64(400_000_000n * COIN),
    );
    await tx5.wait();

    balance = await getPrivateBalanceERC20(token1Address, "carol");
    expect(balance).to.equal(400_000_000n * COIN);
    // BOB and CAROL are market makers, BOB starts with 100M token0 and 200M token1, CAROL starts with 200M token0 and 400M token1

    console.log("Initial balances of market makers (Bob and Carol) : ");
    console.log("Bob's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "bob")) / COIN);
    console.log("Bob's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "bob")) / COIN);
    console.log("Carol's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "carol")) / COIN);
    console.log("Carol's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "carol")) / COIN);

    const tx6 = await token0["transfer(address,bytes)"](
      this.signers.dave.address,
      instances0.alice.encrypt64(1_000_000n * COIN),
    );
    await tx6.wait();
    const tx6bis = await token1["transfer(address,bytes)"](
      this.signers.dave.address,
      instances1.alice.encrypt64(0n * COIN), // to obfuscate the direction of the swap later, needed to initialize dave's token1 balance
    );
    await tx6bis.wait();

    const tx7 = await token1["transfer(address,bytes)"](
      this.signers.eve.address,
      instances1.alice.encrypt64(1_000_000n * COIN),
    );
    await tx7.wait();
    const tx7bis = await token0["transfer(address,bytes)"](
      this.signers.eve.address,
      instances0.alice.encrypt64(0n * COIN), // to obfuscate the direction of the swap later, needed to initialize eve's token0 balance
    );
    await tx7bis.wait();

    console.log("Initial balances of traders (Dave and Eve) : ");
    console.log("Dave's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "dave")) / COIN);
    console.log("Dave's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "dave")) / COIN);
    console.log("Eve's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "eve")) / COIN);
    console.log("Eve's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "eve")) / COIN, "\n");

    const dexFactory = await deployEncryptedDEXFactoryFixture();
    const tx8 = await dexFactory.createPair(token0Address, token1Address);
    await tx8.wait();

    const pairAddress = await dexFactory.getPair(token0Address, token1Address);
    const pair = await ethers.getContractAt("EncryptedDEXPair", pairAddress);
    console.log("DEX contract was deployed for pair token0/token1 \n");

    const instancesPair = await createInstances(pairAddress, ethers, this.signers);

    const tx9 = await token0
      .connect(this.signers.bob)
      ["approve(address,bytes)"](pairAddress, instances0.bob.encrypt64(100_000_000n * COIN));
    await tx9.wait();
    const tx10 = await token1
      .connect(this.signers.bob)
      ["approve(address,bytes)"](pairAddress, instances1.bob.encrypt64(200_000_000n * COIN));
    await tx10.wait();

    const tx11 = await pair
      .connect(this.signers.bob)
      .addLiquidity(
        instancesPair.bob.encrypt64(100_000_000n * COIN),
        instancesPair.bob.encrypt64(200_000_000n * COIN),
        this.signers.bob.address,
        0n,
      );
    await tx11.wait();
    console.log("Bob submitted an addLiquidity order at tradingEpoch ", await pair.currentTradingEpoch());

    const tx12 = await token0
      .connect(this.signers.carol)
      ["approve(address,bytes)"](pairAddress, instances0.carol.encrypt64(200_000_000n * COIN));
    await tx12.wait();
    const tx13 = await token1
      .connect(this.signers.carol)
      ["approve(address,bytes)"](pairAddress, instances0.carol.encrypt64(400_000_000n * COIN));
    await tx13.wait();
    const tx14 = await pair
      .connect(this.signers.carol)
      .addLiquidity(
        instancesPair.carol.encrypt64(200_000_000n * COIN),
        instancesPair.carol.encrypt64(400_000_000n * COIN),
        this.signers.carol.address,
        0n,
      );
    await tx14.wait();
    console.log("Carol submitted an addLiquidity order at tradingEpoch ", await pair.currentTradingEpoch(), "\n");

    const tx15 = await pair.batchSettlement();
    await tx15.wait();

    console.log(
      "Batch Settlement was confirmed with threshold decryptions for tradingEpoch ",
      (await pair.currentTradingEpoch()) - 1n,
    );
    console.log("New reserves for tradingEpoch ", await pair.currentTradingEpoch(), " are now publicly revealed : ");
    let [reserve0, reserve1] = await pair.getReserves();
    console.log("Reserve token0 ", reserve0 / COIN);
    console.log("Reserve token1 ", reserve1 / COIN, "\n");

    const tx16 = await pair.claimMint(0n, this.signers.bob.address);
    await tx16.wait();
    const tx17 = await pair.claimMint(0n, this.signers.carol.address);
    await tx17.wait();
    balance = await getPrivateBalanceERC20(pairAddress, "bob");
    console.log("Bob now owns a private balance of ", balance / COIN, " liquidity tokens");
    balance = await getPrivateBalanceERC20(pairAddress, "carol");
    console.log("Carol now owns a private balance of ", balance / COIN, " liquidity tokens \n");

    const tx18 = await token0
      .connect(this.signers.dave)
      ["approve(address,bytes)"](pairAddress, instances0.bob.encrypt64(100_000_000n * COIN));
    await tx18.wait();
    const tx19 = await token1
      .connect(this.signers.dave)
      ["approve(address,bytes)"](pairAddress, instances1.bob.encrypt64(100_000_000n * COIN));
    await tx19.wait();
    const tx20 = await pair
      .connect(this.signers.dave)
      .swapTokens(
        instancesPair.dave.encrypt64(1_000_000n * COIN),
        instancesPair.dave.encrypt64(0n * COIN),
        this.signers.dave.address,
        1n,
      );
    await tx20.wait();
    console.log("Dave submitted a swap order at tradingEpoch ", await pair.currentTradingEpoch(), "\n");

    const tx21 = await token0
      .connect(this.signers.eve)
      ["approve(address,bytes)"](pairAddress, instances0.bob.encrypt64(100_000_000n * COIN));
    await tx21.wait();
    const tx22 = await token1
      .connect(this.signers.eve)
      ["approve(address,bytes)"](pairAddress, instances1.bob.encrypt64(100_000_000n * COIN));
    await tx22.wait();
    const tx23 = await pair
      .connect(this.signers.eve)
      .swapTokens(
        instancesPair.eve.encrypt64(0n * COIN),
        instancesPair.eve.encrypt64(1_000_000n * COIN),
        this.signers.eve.address,
        1n,
      );
    await tx23.wait();
    console.log("Eve submitted a swap order at tradingEpoch ", await pair.currentTradingEpoch(), "\n");

    const tx24 = await pair.batchSettlement({ gasLimit: 10_000_000 });
    await tx24.wait();

    console.log(
      "Batch Settlement was confirmed with threshold decryptions for tradingEpoch ",
      (await pair.currentTradingEpoch()) - 1n,
    );
    console.log("New reserves for tradingEpoch ", await pair.currentTradingEpoch(), " are now publicly revealed : ");
    [reserve0, reserve1] = await pair.getReserves();
    console.log("Reserve token0 ", reserve0 / COIN);
    console.log("Reserve token1 ", reserve1 / COIN, "\n");

    const tx25 = await pair.claimSwap(1n, this.signers.dave.address);
    await tx25.wait();
    const tx26 = await pair.claimSwap(1n, this.signers.eve.address);
    await tx26.wait();

    console.log("New balances of traders (Dave and Eve) : ");
    console.log("Dave's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "dave")) / COIN);
    console.log("Dave's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "dave")) / COIN);
    console.log("Eve's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "eve")) / COIN);
    console.log("Eve's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "eve")) / COIN, "\n");

    const tx27 = await pair
      .connect(this.signers.bob)
      .removeLiquidity(instancesPair.bob.encrypt64((149999900n / 2n) * COIN), this.signers.bob.address, 2n);
    await tx27.wait();
    console.log("Bob submitted a removeLiquidity order at tradingEpoch ", await pair.currentTradingEpoch());

    const tx28 = await pair
      .connect(this.signers.carol)
      .removeLiquidity(instancesPair.carol.encrypt64((299999900n / 2n) * COIN), this.signers.carol.address, 2n);
    await tx28.wait();
    console.log("Carol submitted a removeLiquidity order at tradingEpoch ", await pair.currentTradingEpoch(), "\n");

    balance = await getPrivateBalanceERC20(pairAddress, "bob");
    console.log("Bob now owns a private balance of ", balance / COIN, " liquidity tokens");
    balance = await getPrivateBalanceERC20(pairAddress, "carol");
    console.log("Carol now owns a private balance of ", balance / COIN, " liquidity tokens \n");

    const tx29 = await pair.batchSettlement({ gasLimit: 10_000_000 });
    await tx29.wait();

    console.log(
      "Batch Settlement was confirmed with threshold decryptions for tradingEpoch ",
      (await pair.currentTradingEpoch()) - 1n,
    );
    console.log("New reserves for tradingEpoch ", await pair.currentTradingEpoch(), " are now publicly revealed : ");
    [reserve0, reserve1] = await pair.getReserves();
    console.log("Reserve token0 ", reserve0 / COIN);
    console.log("Reserve token1 ", reserve1 / COIN, "\n");

    const tx30 = await pair.claimBurn(2n, this.signers.bob.address);
    await tx30.wait();
    const tx31 = await pair.claimBurn(2n, this.signers.carol.address);
    await tx31.wait();

    console.log("New balances of market makers (Bob and Carol) : ");
    console.log("Bob's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "bob")) / COIN);
    console.log("Bob's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "bob")) / COIN);
    console.log("Carol's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "carol")) / COIN);
    console.log("Carol's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "carol")) / COIN);
  });

  it("Encrypted DEX Pool - single epoch (addLiquidity+swap)", async function () {
    const COIN = 2n ** 32n;
    let token0 = await deployEncryptedERC20Fixture();
    let token0Address = await token0.getAddress();
    let token1 = await deployEncryptedERC20Fixture();
    let token1Address = await token1.getAddress();

    BigInt(token0Address) > BigInt(token1Address) ? ([token0, token1] = [token1, token0]) : null; // sort tokens according to addresses
    token0Address = await token0.getAddress();
    token1Address = await token1.getAddress();

    const tx0 = await token0.mint(2_000_000_000n * COIN);
    await tx0.wait();
    const instances0 = await createInstances(token0Address, ethers, this.signers);
    const tx1 = await token1.mint(2_000_000_000n * COIN);
    await tx1.wait();
    const instances1 = await createInstances(token1Address, ethers, this.signers);
    let balance = await getPrivateBalanceERC20(token0Address, "alice");
    expect(balance).to.equal(2_000_000_000n * COIN);
    const totalSupply = await token0.totalSupply();
    expect(totalSupply).to.equal(2_000_000_000n * COIN);

    const tx2 = await token0["transfer(address,bytes)"](
      this.signers.bob.address,
      instances0.alice.encrypt64(100_000_000n * COIN),
    );
    await tx2.wait();

    balance = await getPrivateBalanceERC20(token0Address, "alice");
    expect(balance).to.equal(1_900_000_000n * COIN);
    balance = await getPrivateBalanceERC20(token0Address, "bob");
    expect(balance).to.equal(100_000_000n * COIN);

    const tx3 = await token0["transfer(address,bytes)"](
      this.signers.carol.address,
      instances0.alice.encrypt64(200_000_000n * COIN),
    );
    await tx3.wait();

    const tx4 = await token1["transfer(address,bytes)"](
      this.signers.bob.address,
      instances1.alice.encrypt64(200_000_000n * COIN),
    );
    await tx4.wait();

    const tx5 = await token1["transfer(address,bytes)"](
      this.signers.carol.address,
      instances1.alice.encrypt64(400_000_000n * COIN),
    );
    await tx5.wait();

    balance = await getPrivateBalanceERC20(token1Address, "carol");
    expect(balance).to.equal(400_000_000n * COIN);
    // BOB and CAROL are market makers, BOB starts with 100M token0 and 200M token1, CAROL starts with 200M token0 and 400M token1

    console.log("Initial balances of market makers (Bob and Carol) : ");
    console.log("Bob's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "bob")) / COIN);
    console.log("Bob's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "bob")) / COIN);
    console.log("Carol's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "carol")) / COIN);
    console.log("Carol's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "carol")) / COIN);

    const tx6 = await token0["transfer(address,bytes)"](
      this.signers.dave.address,
      instances0.alice.encrypt64(1_000_000n * COIN),
    );
    await tx6.wait();
    const tx6bis = await token1["transfer(address,bytes)"](
      this.signers.dave.address,
      instances1.alice.encrypt64(0n * COIN), // to obfuscate the direction of the swap later, needed to initialize dave's token1 balance
    );
    await tx6bis.wait();

    const tx7 = await token1["transfer(address,bytes)"](
      this.signers.eve.address,
      instances1.alice.encrypt64(1_000_000n * COIN),
    );
    await tx7.wait();
    const tx7bis = await token0["transfer(address,bytes)"](
      this.signers.eve.address,
      instances0.alice.encrypt64(0n * COIN), // to obfuscate the direction of the swap later, needed to initialize eve's token0 balance
    );
    await tx7bis.wait();

    console.log("Initial balances of traders (Dave and Eve) : ");
    console.log("Dave's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "dave")) / COIN);
    console.log("Dave's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "dave")) / COIN);
    console.log("Eve's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "eve")) / COIN);
    console.log("Eve's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "eve")) / COIN, "\n");

    const dexFactory = await deployEncryptedDEXFactoryFixture();
    const tx8 = await dexFactory.createPair(token0Address, token1Address);
    await tx8.wait();

    const pairAddress = await dexFactory.getPair(token0Address, token1Address);
    const pair = await ethers.getContractAt("EncryptedDEXPair", pairAddress);
    console.log("DEX contract was deployed for pair token0/token1 \n");

    const instancesPair = await createInstances(pairAddress, ethers, this.signers);

    const tx9 = await token0
      .connect(this.signers.bob)
      ["approve(address,bytes)"](pairAddress, instances0.bob.encrypt64(100_000_000n * COIN));
    await tx9.wait();
    const tx10 = await token1
      .connect(this.signers.bob)
      ["approve(address,bytes)"](pairAddress, instances1.bob.encrypt64(200_000_000n * COIN));
    await tx10.wait();

    const tx11 = await pair
      .connect(this.signers.bob)
      .addLiquidity(
        instancesPair.bob.encrypt64(100_000_000n * COIN),
        instancesPair.bob.encrypt64(200_000_000n * COIN),
        this.signers.bob.address,
        0n,
      );
    await tx11.wait();
    console.log("Bob submitted an addLiquidity order at tradingEpoch ", await pair.currentTradingEpoch());

    const tx12 = await token0
      .connect(this.signers.carol)
      ["approve(address,bytes)"](pairAddress, instances0.carol.encrypt64(200_000_000n * COIN));
    await tx12.wait();
    const tx13 = await token1
      .connect(this.signers.carol)
      ["approve(address,bytes)"](pairAddress, instances0.carol.encrypt64(400_000_000n * COIN));
    await tx13.wait();
    const tx14 = await pair
      .connect(this.signers.carol)
      .addLiquidity(
        instancesPair.carol.encrypt64(200_000_000n * COIN),
        instancesPair.carol.encrypt64(400_000_000n * COIN),
        this.signers.carol.address,
        0n,
      );
    await tx14.wait();
    console.log("Carol submitted an addLiquidity order at tradingEpoch ", await pair.currentTradingEpoch(), "\n");

    const tx18 = await token0
      .connect(this.signers.dave)
      ["approve(address,bytes)"](pairAddress, instances0.bob.encrypt64(100_000_000n * COIN));
    await tx18.wait();
    const tx19 = await token1
      .connect(this.signers.dave)
      ["approve(address,bytes)"](pairAddress, instances1.bob.encrypt64(100_000_000n * COIN));
    await tx19.wait();
    const tx20 = await pair
      .connect(this.signers.dave)
      .swapTokens(
        instancesPair.dave.encrypt64(1_000_000n * COIN),
        instancesPair.dave.encrypt64(0n * COIN),
        this.signers.dave.address,
        1n,
      );
    await tx20.wait();
    console.log("Dave submitted a swap order at tradingEpoch ", await pair.currentTradingEpoch(), "\n");

    const tx21 = await token0
      .connect(this.signers.eve)
      ["approve(address,bytes)"](pairAddress, instances0.bob.encrypt64(100_000_000n * COIN));
    await tx21.wait();
    const tx22 = await token1
      .connect(this.signers.eve)
      ["approve(address,bytes)"](pairAddress, instances1.bob.encrypt64(100_000_000n * COIN));
    await tx22.wait();
    const tx23 = await pair
      .connect(this.signers.eve)
      .swapTokens(
        instancesPair.eve.encrypt64(0n * COIN),
        instancesPair.eve.encrypt64(1_000_000n * COIN),
        this.signers.eve.address,
        1n,
      );
    await tx23.wait();
    console.log("Eve submitted a swap order at tradingEpoch ", await pair.currentTradingEpoch(), "\n");

    const tx24 = await pair.batchSettlement({ gasLimit: 10_000_000 });
    await tx24.wait();

    console.log(
      "Batch Settlement was confirmed with threshold decryptions for tradingEpoch ",
      (await pair.currentTradingEpoch()) - 1n,
    );
    console.log("New reserves for tradingEpoch ", await pair.currentTradingEpoch(), " are now publicly revealed : ");
    let [reserve0, reserve1] = await pair.getReserves();
    console.log("Reserve token0 ", reserve0 / COIN);
    console.log("Reserve token1 ", reserve1 / COIN, "\n");

    const tx25 = await pair.claimSwap(0n, this.signers.dave.address);
    await tx25.wait();
    const tx26 = await pair.claimSwap(0n, this.signers.eve.address);
    await tx26.wait();

    const tx16 = await pair.claimMint(0n, this.signers.bob.address);
    await tx16.wait();
    const tx17 = await pair.claimMint(0n, this.signers.carol.address);
    await tx17.wait();
    balance = await getPrivateBalanceERC20(pairAddress, "bob");
    console.log("Bob now owns a private balance of ", balance / COIN, " liquidity tokens");
    balance = await getPrivateBalanceERC20(pairAddress, "carol");
    console.log("Carol now owns a private balance of ", balance / COIN, " liquidity tokens \n");

    console.log("New balances of traders (Dave and Eve) : ");
    console.log("Dave's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "dave")) / COIN);
    console.log("Dave's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "dave")) / COIN);
    console.log("Eve's token0 balance : ", (await getPrivateBalanceERC20(token0Address, "eve")) / COIN);
    console.log("Eve's token1 balance : ", (await getPrivateBalanceERC20(token1Address, "eve")) / COIN, "\n");
  });
});
