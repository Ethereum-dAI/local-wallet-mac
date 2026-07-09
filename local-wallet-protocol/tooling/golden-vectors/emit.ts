import { mkdirSync, writeFileSync } from "node:fs";
import { getEntryPoint, KERNEL_V3_3 } from "@zerodev/sdk/constants";
import { createKernelAccount } from "@zerodev/sdk";
import { signerToEcdsaValidator } from "@zerodev/ecdsa-validator";
import { toPermissionValidator } from "@zerodev/permissions";
import { toECDSASigner } from "@zerodev/permissions/signers";
import {
  CallPolicyVersion,
  toCallPolicy,
  toGasPolicy,
  toRateLimitPolicy,
  toTimestampPolicy
} from "@zerodev/permissions/policies";
import {
  createPublicClient,
  hashTypedData,
  http,
  parseAbi,
  type Address
} from "viem";
import { getUserOperationHash } from "viem/account-abstraction";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

const SESSION_PK = "0x4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d";
const OWNER_PK = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const SESSION_KEY: Address = privateKeyToAccount(SESSION_PK).address;
const ACCOUNT: Address = "0x000000000000000000000000000000000000dEaD";
const USDC: Address = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
const ROUTER: Address = "0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E";
const CHAIN_ID = 11155111;

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http("https://ethereum-sepolia-rpc.publicnode.com")
});
const entryPoint = getEntryPoint("0.7");
const kernelVersion = KERNEL_V3_3;

const policies = [
  toGasPolicy({ allowed: 5_000_000_000_000_000n }),
  toRateLimitPolicy({ count: 20, interval: 86400 }),
  toTimestampPolicy({ validAfter: 0, validUntil: 1_900_000_000 }),
  toCallPolicy({
    policyVersion: CallPolicyVersion.V0_0_5,
    permissions: [
      {
        target: USDC,
        valueLimit: 0n,
        abi: parseAbi(["function transfer(address,uint256)"]),
        functionName: "transfer",
        args: [null, null]
      },
      {
        target: USDC,
        valueLimit: 0n,
        abi: parseAbi(["function approve(address,uint256)"]),
        functionName: "approve",
        args: [null, null]
      }
    ]
  })
];

const sessionAccount = privateKeyToAccount(SESSION_PK);
const sessionSigner = await toECDSASigner({ signer: sessionAccount });
const permissionPlugin = await toPermissionValidator(publicClient, {
  entryPoint,
  kernelVersion,
  signer: sessionSigner,
  policies
});

const ownerAccount = privateKeyToAccount(OWNER_PK);
const ecdsaValidator = await signerToEcdsaValidator(publicClient, {
  entryPoint,
  kernelVersion,
  signer: ownerAccount
});

const account = await createKernelAccount(publicClient, {
  entryPoint,
  kernelVersion,
  plugins: {
    sudo: ecdsaValidator,
    regular: permissionPlugin
  },
  address: ACCOUNT
});

const dummyUserOp = {
  sender: ACCOUNT,
  nonce: 0n,
  callData: "0x" as const,
  callGasLimit: 100000n,
  verificationGasLimit: 200000n,
  preVerificationGas: 50000n,
  maxFeePerGas: 1000000000n,
  maxPriorityFeePerGas: 1000000000n
};

const out: Record<string, unknown> = {
  meta: {
    SESSION_KEY,
    SESSION_PK,
    OWNER_PK,
    ACCOUNT,
    USDC,
    ROUTER,
    CHAIN_ID,
    kernelVersion
  },
  permissionId: permissionPlugin.getIdentifier(),
  enableData: await permissionPlugin.getEnableData(ACCOUNT),
  policies: policies.map((policy: any) => ({
    info: policy.getPolicyInfoInBytes(),
    data: policy.getPolicyData()
  })),
  signer: {
    contract: (sessionSigner as any).signerContractAddress,
    data: (sessionSigner as any).getSignerData()
  }
};

const enableTypedData = await (account as any).kernelPluginManager.getPluginsEnableTypedData(ACCOUNT);
out.enableTypedData = enableTypedData;
out.enableDigest = hashTypedData(enableTypedData as any);
out.installedUserOpSig = await (permissionPlugin as any).signUserOperation({
  ...dummyUserOp,
  signature: "0x"
});
out.enableUserOpSig = await (account as any).signUserOperation({
  ...dummyUserOp,
  signature: "0x"
});
out.dummyUserOpHash = getUserOperationHash({
  chainId: CHAIN_ID,
  entryPointAddress: entryPoint.address,
  entryPointVersion: "0.7",
  userOperation: {
    ...dummyUserOp,
    signature: "0x"
  } as any
});

mkdirSync("out", { recursive: true });
writeFileSync(
  "out/permission.json",
  JSON.stringify(out, (_key, value) => (typeof value === "bigint" ? value.toString() : value), 2)
);
console.log("wrote out/permission.json");
