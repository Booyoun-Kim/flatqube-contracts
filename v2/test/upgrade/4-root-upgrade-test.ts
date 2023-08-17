import { Constants } from "utils/consts";
import { expect } from "chai";

import { Address, Contract, toNano } from "locklift";
import {
  DexPlatformAbi,
  DexRootAbi,
  DexVaultAbi,
  DexAccountAbi,
  DexPairAbi,
  TestNewDexRootAbi,
} from "build/factorySource";
import { Account } from "everscale-standalone-client";
import { ContractData } from "locklift/internal/factory";

interface IRootData {
  vault: Address;
  owner: Address;
  pending_owner: Address;
  active: boolean;
  current_version: string;
  platform_code: string;
  account_code: string;
  pair_code: string;
  pair_version: string;
  account_version: string;
}

let DexRoot: ContractData<DexRootAbi>;
let DexVault: ContractData<DexVaultAbi>;
let DexPlatform: ContractData<DexPlatformAbi>;
let DexAccount: ContractData<DexAccountAbi>;
let DexPair: ContractData<DexPairAbi>;
let NewDexRoot: ContractData<TestNewDexRootAbi>;

let account: Account;
let dexRoot: Contract<DexRootAbi>;
let newDexRoot: Contract<TestNewDexRootAbi>;
let dexVault: Contract<DexVaultAbi>;

let oldRootData: IRootData = {} as IRootData;
let newRootData: IRootData = {} as IRootData;

const loadRootData = async (
  root: Contract<DexRootAbi> | Contract<TestNewDexRootAbi>,
) => {
  const data: IRootData = {} as IRootData;
  data.platform_code = (
    await root.methods.platform_code().call()
  ).platform_code;
  data.account_code = (
    await root.methods.getAccountCode({ answerId: 0 }).call()
  ).value0;
  data.account_version = (
    await root.methods.getAccountVersion({ answerId: 0 }).call()
  ).value0;
  data.pair_code = (
    await root.methods.getPairCode({ pool_type: 1, answerId: 0 }).call()
  ).value0;
  data.pair_version = (
    await root.methods.getPairVersion({ pool_type: 1, answerId: 0 }).call()
  ).value0;
  data.active = (await root.methods.isActive({ answerId: 0 }).call()).value0;
  data.owner = (await root.methods.getOwner({ answerId: 0 }).call()).dex_owner;
  data.vault = (await root.methods.getVault({ answerId: 0 }).call()).value0;
  data.pending_owner = (
    await root.methods.getPendingOwner({ answerId: 0 }).call()
  ).dex_pending_owner;
  return data;
};

describe("Test Dex Root contract upgrade", async function () {
  this.timeout(Constants.TESTS_TIMEOUT);
  before("Load contracts", async function () {
    account = locklift.deployments.getAccount("Account1").account;
    DexRoot = await locklift.factory.getContractArtifacts("DexRoot");
    DexVault = await locklift.factory.getContractArtifacts("DexVault");
    DexPlatform = await locklift.factory.getContractArtifacts("DexPlatform");
    DexAccount = await locklift.factory.getContractArtifacts("DexAccount");
    DexPair = await locklift.factory.getContractArtifacts("DexPair");
    NewDexRoot = await locklift.factory.getContractArtifacts("TestNewDexRoot");

    dexRoot = locklift.deployments.getContract<DexRootAbi>("DexRoot");
    dexVault = locklift.deployments.getContract<DexVaultAbi>("DexVault");

    oldRootData = await loadRootData(dexRoot);

    console.log(`Upgrading DexRoot contract: ${dexRoot.address}`);
    await dexRoot.methods
      .upgrade({
        code: NewDexRoot.code,
      })
      .send({
        from: account.address,
        amount: toNano(11),
      });

    newDexRoot = locklift.factory.getDeployedContract(
      "TestNewDexRoot",
      dexVault.address,
    );
    newRootData = await loadRootData(newDexRoot);
  });
  describe("Check DexRoot after upgrade", async function () {
    it("Check New Function", async function () {
      expect(
        (await newDexRoot.methods.newFunc().call()).value0.toString(),
      ).to.equal("New Root", "DexRoot new function incorrect");
    });
    it("Check All data correct installed in new contract", async function () {
      expect(newRootData.platform_code).to.equal(
        oldRootData.platform_code,
        "New platform_code value incorrect",
      );
      expect(newRootData.account_code).to.equal(
        oldRootData.account_code,
        "New account_code value incorrect",
      );
      expect(newRootData.account_version).to.equal(
        oldRootData.account_version,
        "New account_version value incorrect",
      );
      expect(newRootData.pair_code).to.equal(
        oldRootData.pair_code,
        "New pair_code value incorrect",
      );
      expect(newRootData.pair_version).to.equal(
        oldRootData.pair_version,
        "New pair_version value incorrect",
      );
      expect(newRootData.active).to.equal(
        oldRootData.active,
        "New active value incorrect",
      );
      expect(newRootData.owner).to.equal(
        oldRootData.owner,
        "New owner value incorrect",
      );
      expect(newRootData.vault).to.equal(
        oldRootData.vault,
        "New vault value incorrect",
      );
      expect(newRootData.pending_owner).to.equal(
        oldRootData.pending_owner,
        "New pending_owner value incorrect",
      );
    });
  });
});
