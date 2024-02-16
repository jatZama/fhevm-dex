import { ethers } from "hardhat";

import type { EncryptedERC20 } from "../../types";
import { createInstances } from "../instance";
import { getSigners } from "../signers";

export async function deployEncryptedERC20Fixture(): Promise<EncryptedERC20> {
  const signers = await getSigners();

  const contractFactory = await ethers.getContractFactory("EncryptedERC20");
  const contract = await contractFactory.connect(signers.alice).deploy("Naraggara", "NARA"); // City of Zama's battle
  await contract.waitForDeployment();

  return contract;
}

export async function getPrivateBalanceERC20(erc20Address: string, userName: string): Promise<BigInt> {
  const signers = await getSigners();
  const erc20 = await ethers.getContractAt("EncryptedERC20", erc20Address);
  const instances = await createInstances(erc20Address, ethers, signers);
  const token = instances[userName].getPublicKey(erc20Address) || {
    signature: "",
    publicKey: "",
  };
  const encryptedBalance = await erc20
    .connect(signers[userName])
    .balanceOf(signers[userName], token.publicKey, token.signature);
  const balance = instances[userName].decrypt(erc20Address, encryptedBalance);
  return balance;
}
