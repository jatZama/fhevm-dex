import { ethers } from "hardhat";

import type { EncryptedDEXFactory } from "../../types";
import { getSigners } from "../signers";

export async function deployEncryptedDEXFactoryFixture(): Promise<EncryptedDEXFactory> {
  const signers = await getSigners();

  const contractFactory = await ethers.getContractFactory("EncryptedDEXFactory");
  const contract = await contractFactory.connect(signers.alice).deploy();
  await contract.waitForDeployment();

  return contract;
}
