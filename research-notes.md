# Reactive Omni 调研笔记 — Set It and Forget It（链上自动止损/止盈）

> 调研时间：2026-11-18。来源：官方文档 https://dev.reactive.network/（2026-11-18 当天抓取全文）及官方 GitHub 仓库。
> 适用范围：**Reactive Omni（新版）**。文档明确指出这是同一条链的升级（余额、已部署合约、存储全部保留），但合约写法变了；旧版称 Legacy / RVM。
> 只做调研，不写项目代码、不部署、不动真钱。

---

## 1. 网络参数速查

| 网络 | Chain ID | RPC URL | 浏览器 | 币种 |
|---|---|---|---|---|
| **Reactive Mainnet** | **1597** | https://mainnet-rpc.rnk.dev/ | https://reactscan.net/ | REACT |
| **Lasna Testnet** | **5318007** | https://lasna-rpc.rnk.dev/ | https://lasna.reactscan.net/ | lREACT |

- **System 合约地址（主网与 Lasna 共用）**：`0x8888888888888888888888888888888888888888`
- 共识：CometBFT，即时最终性（无重组），出块约 1 秒。标准 EVM 链，无 RVM、无专用 precompile；`cast` / Foundry 开箱即用；Reactscan 与 Blockscout 均可用。
- 合约状态可在 Reactscan 上查：`active`（正常执行）/ `inactive`（有未清债务，见第 4 节）。

### 水龙头（Lasna lREACT，无网页水龙头）

向 Sepolia 上的水龙头合约**直接转 Sepolia ETH**（MetaMask 或任意钱包），或调 `request(address)`：

| 水龙头合约 | 所在链 |
|---|---|
| `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` | Ethereum Sepolia |
| `0x2afaFD298b23b62760711756088F75B7409f5967` | Base Sepolia |

- 汇率：**1 ETH → 100 lREACT**。
- **单笔最多 5 ETH（最多得 500 lREACT），超额部分直接丢失，不产生额外 lREACT。**
- `cast` 方式：
  ```bash
  cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
    --rpc-url $ETHEREUM_SEPOLIA_RPC --private-key $ETHEREUM_SEPOLIA_PRIVATE_KEY \
    "request(address)" $WALLET_ADDR --value 0.1ether
  ```

---

## 2. 支持的 Origin / Destination 链与回调代理地址

规则：**主网 origin 只能配主网 destination，测试网 origin 只能配测试网 destination，不能混用。**

### 主网（origin / destination 均 ✅）

| 链 | Chain ID | Callback Proxy |
|---|---|---|
| Arbitrum | 42161 | `0xaee8d2deBaB5bE353bfec167C58a549923892e11` |
| Avalanche | 43114 | `0x8bdfC7e564B90b31c49Cf1079d4c44400F4e14B4` |
| Base | 8453 | `0xCc780DdE33f56f55dE778D42c930959374a4a068` |
| BSC | 56 | `0xfc41eE9d3A836b41399BEcce83b06B3e5650f3BB` |
| Ethereum | 1 | `0xFCE1F192F489c988392aBC16E91e359d540d94Fe` |
| HyperEVM | 999 | `0x754120EC7a6eF81E4c5c835AA603C63Da64693E6` |
| Reactive（主网） | 1597 | `0x8888888888888888888888888888888888888888`（即 System 合约本身） |
| Robinhood | 4663 | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |
| Unichain | 130 | `0x754120EC7a6eF81E4c5c835AA603C63Da64693E6` |

### 测试网（origin / destination 均 ✅）

| 链 | Chain ID | Callback Proxy |
|---|---|---|
| Base Sepolia | 84532 | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |
| Ethereum Sepolia | 11155111 | `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4` |
| Reactive Lasna | 5318007 | `0x8888888888888888888888888888888888888888`（即 System 合约本身） |
| Unichain Sepolia | 1301 | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` |

> 对黑客松最相关的组合：origin = Ethereum Sepolia（11155111，Chainlink/Pyth/Uniswap 演示都在这条链）或 Unichain Sepolia（1301），destination = 同一条测试网；reactive 合约部署在 Lasna（5318007）。
> 注意：文档的 Origin/Destination 页**没有列出 Sepolia 上的 Chainlink/Pyth 官方喂价合约地址**，做价格监控要么用 Uniswap V2 pair 的 `Sync` 事件（官方止损 demo 的做法），要么自己查 Sepolia 上的 Chainlink/Pyth feed 地址。

---

## 3. Reactive 合约（Omni 写法）

### 3.1 继承与基类

- 继承 `AbstractReactive`（`@reactive/src/base/AbstractReactive.sol`，仓库见 §7），它自带 `AbstractPayer`。
- 另需 import `IReactive`（只为 `/// @inheritdoc IReactive` 注释）和 `ISystemContract`（用到回调配置结构体时）。
- 基类提供的名字：

| 名字 | 来源 | 用途 |
|---|---|---|
| `SYSTEM` | `AbstractReactive` | System 合约 `0x8888…8888`，订阅与请求回调都走它 |
| `REACTIVE_IGNORE` | `AbstractReactive` | 任意 topic 位置的通配符，见 §3.3 |
| `onlySystem` | `AbstractReactive` | 只允许 System 合约调 `react()`，否则 revert `NotAuthorized` |
| `LogRecord` | `IReactive` | `react()` 收到的结构体 |
| `_SERVICE_PROVIDER` / `onlyServiceProvider` | `AbstractPayer` | 允许扣费的合约（reactive 合约即 `SYSTEM`）；`onlySystem` 就是这个检查的别名 |
| `pay(uint256)` | `AbstractPayer` | 已实现并验 caller，**不要自己写** |
| `_coverDebt()` | `AbstractPayer` | internal，用余额结清欠款；想对外暴露需自己包一层 `coverDebt()` |
| `receive()` | `AbstractPayer` | payable，可 override |

### 3.2 最小 reactive 合约（直接取自官方文档 Reactive Contracts 页）

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

contract MyReactive is AbstractReactive {
    uint256 private immutable _originChainId;
    address private immutable _originContract;
    uint256 private immutable _topic0;

    // `payable` so the contract can be funded at deployment.
    constructor(uint256 originChainId_, address originContract_, uint256 topic0_) payable {
        _originChainId = originChainId_;
        _originContract = originContract_;
        _topic0 = topic0_;

        SYSTEM.subscribe(
            originChainId_,
            originContract_,
            topic0_,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        // Your logic here.
    }
}
```

三点缺一不可：① 继承 `AbstractReactive`；② `react()` 带 `onlySystem`（否则任何人可伪造 log 记录调你）；③ **部署前/部署时充钱**（见 §4）。

### 3.3 订阅 API

```solidity
function subscribe(
    uint256 chainId_,
    address contract_,
    uint256 topic0_,
    uint256 topic1_,
    uint256 topic2_,
    uint256 topic3_
) external;

function unsubscribe(
    uint256 chainId_,
    address contract_,
    uint256 topic0_,
    uint256 topic1_,
    uint256 topic2_,
    uint256 topic3_
) external;
```

参数含义（`ISubscriptionService` 注释原文）：

| 参数 | 含义 | 通配符 |
|---|---|---|
| `chainId_` | 源链 EIP-155 chain ID | `0` = 任意链 |
| `contract_` | 要监听的合约地址 | `address(0)` = 该链上任意合约 |
| `topic0_`–`topic3_` | topic 0（通常是事件签名哈希），topic 1–3 是 indexed 参数 | `REACTIVE_IGNORE` = 该位置任意值 |

- **`REACTIVE_IGNORE` 的值**（`reactive-lib-omni/src/base/AbstractReactive.sol`）：
  ```
  uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
  ```
- 限制：
  - **至少一个条件必须具体**：不能订阅“所有链所有合约所有事件”。
  - 只做**精确相等匹配**，无范围/比较/位运算过滤；价格阈值判断必须在 `react()` 里自己算。
  - 一个订阅只表达一组条件（无 OR）；要监听多个合约/事件类型就多次调 `subscribe()`。
  - 重复订阅无害但浪费 gas；订阅存在**节点里，不存在合约存储**，链上读不回来，自己记。
  - `unsubscribe()` 必须六个参数**完全一致**才生效，差一个就静默失败（订阅还留着）。建议用内部 `_subscribe()` / `_unsubscribe()` helper 把六个条件收敛到一处。
  - 订阅不限于构造函数：`react()` 里也可以订阅/退订。停掉再重启的合约要先结清债务（`_coverDebt()`），否则有债就收不到任何事件。
- CRON 定时事件（可做定期巡检，如每 N 分钟查一次持仓健康度）：订阅 legacy system 合约 `0x0000000000000000000000000000000000fffFfF` 发出的 `Cron` 事件，chainId 用 `block.chainid`。topic0：

| 事件 | 间隔 | 约时间 | topic0 |
|---|---|---|---|
| `Cron1` | 每块 | ~1 秒 | `0xf02d6ea5c22a71cffe930a4523fcb4f129be6c804db50e4202fb4e0b07ccb514` |
| `Cron10` | 每 10 块 | ~10 秒 | `0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687` |
| `Cron100` | 每 100 块 | ~2 分钟 | `0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70` |
| `Cron1000` | 每 1000 块 | ~17 分钟 | `0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4` |
| `Cron10000` | 每 10000 块 | ~3 小时 | `0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56` |

  注意：Cron 按 tick 计费，**每个 tick 都收费，哪怕 `react()` 里什么都没做**；选满足需求的最长间隔，并留退订开关。一个区块能同时触发多个 Cron（如第 10 块同时触发 Cron1 和 Cron10），订阅了两个就收到两次 reactive 交易、付两次钱。Cron 事件唯一参数 `number`（区块号，非 indexed，在 `log_.data` 里为单个 `uint256`），一般直接读 `block.number` 即可。

### 3.4 `react(LogRecord)` 与 LogRecord 结构体

```solidity
struct LogRecord {
    uint256 chainId;
    address contractAddress;
    uint256 topic0;
    uint256 topic1;
    uint256 topic2;
    uint256 topic3;
    bytes   data;
    uint256 blockNumber;
    uint256 opCode;
    uint256 blockHash;
    uint256 txHash;
    uint256 logIndex;
}
```

- `data`：只含**非 indexed 参数**的 ABI 编码；`opCode` = 原 log 的 topic 数量（如 `LOG3` 到达时 `opCode == 3`）；`blockHash` / `txHash` 是 `uint256` 而非 `bytes32`，比较时需转换。
- 未使用的 topic 位置为 0，但 **topic 位置为 0 不代表该 log 没有这个 topic**（如 ERC-20 mint 的 `Transfer` 的 `from` 就是 `address(0)`）；判断 topic 数以 `opCode` 为准，解码前先检查 `opCode`。
- 多订阅时先按 `topic0` 分流。ERC-20 `Transfer(address indexed from, address indexed to, uint256 value)` 是 LOG3：两个地址已在 topic1/2，只有 amount 在 `data` 里。
- **不要用 revert 做过滤**：`react()` revert 会被 system 合约捕获、记 `ReactiveContractReverted` 事件，**gas 照收**。不匹配的 log 直接 fall through 返回即可。
- `react()` 是 Reactive 链上的普通交易，可做任何普通函数能做的事，包括订阅/退订/请求回调。

### 3.5 请求回调：`requestCallbackV_1_0`

```solidity
enum CallbackVersion { V_1_0 }

struct CallbackConfiguration_V_1_0 {
    uint256 chainId;    // destination network
    address recipient;  // target contract on the destination chain
    uint64  gasLimit;   // execution gas limit
    bytes   payload;    // ABI-encoded function call
}

function requestCallback(CallbackVersion version_, bytes memory config_) external;
function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external;
```

- 用 `requestCallbackV_1_0()`（直接传 struct）；`requestCallback()` 是通用入口，需手动 ABI 编码版本配置，不认识的版本 revert `InvalidCallbackVersion`。目前只有 V_1_0。
- **payload 第一个参数必须预留为 `address`**：Reactive 会把 payload 的前 160 位替换成**发起回调的 reactive 合约地址**，目标链靠它鉴权（见 §5）。编码时第一个参数传 `address(0)` 占位，忘记预留是回调失败最常见的原因。
- 官方示例（`CALLBACK_GAS_LIMIT = 1000000`）：
  ```solidity
  uint64 private constant CALLBACK_GAS_LIMIT = 1000000;

  function _requestCallback(uint256 chainId_, address recipient_, uint256 value_) internal {
      bytes memory payload = abi.encodeWithSignature(
          "myCallback(address,uint256)",
          address(0),
          value_
      );
      SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({
          chainId: chainId_,
          recipient: recipient_,
          gasLimit: CALLBACK_GAS_LIMIT,
          payload: payload
      }));
  }
  ```
- 请求回调不需要先有事件：它是 `SYSTEM` 上的普通调用，任何外部方法也能调，但通常在 `react()` 里发。
- 回调也可以发给 Reactive 自身（`chainId: block.chainid`，`recipient: address(this)`），在新交易里跑逻辑；接收方法仍需 §5 的鉴权。
- 旧的 `emit Callback(...)` 事件方式**仍可用但已废弃**。两种方式都会让 system 合约发出 `CallbackRequest` 事件：
  ```solidity
  event CallbackRequest(
      uint256 indexed chainId,
      address indexed sender,
      address indexed recipient,
      CallbackVersion version,
      bytes configuration
  );
  ```

---

## 4. 经济模型：谁付钱、付多少、怎么充

### 4.1 两个收费点（币种不同）

| 执行 | 谁付 | 用什么币 | 向谁收费 |
|---|---|---|---|
| reactive 合约的 `react()` | reactive 合约自己 | **REACT**（Lasna 上是 lREACT） | System 合约 `0x8888…8888` |
| 目标链回调 | **回调合约（接收方）**，不是发起回调的 reactive 合约 | **目标链原生币**（ETH / BNB / …，绝不是 REACT） | 该链的 callback proxy |

### 4.2 计费公式（reactive 交易与回调共用同一公式）

```
fee = p_base · C · (g_used + K)
```

- `p_base` = `max(tx.gasprice, block.basefee)`
- `C` = 定价系数，读 `_gasPriceCoeffPer1000()` 再除以 1000
- `g_used` = 实际消耗的 gas
- `K` = 固定附加 gas，读 `_extraGas()`
- 费用在**执行同一笔交易内收取**，付给该交易的发起方（提交 reactive 交易的验证者 / 投递回调的人）。费用不沉淀在 system 合约里。
- System 合约默认值：系数 1000（即 C=1）、`_extraGas` = 100,000 gas、`_maxChargeGas`（付费结算 gas 预算）= 50,000。owner 可改，**以链上查询为准**：
  ```bash
  cast call $SYSTEM_CONTRACT_ADDR "_gasPriceCoeffPer1000()" --rpc-url $REACTIVE_RPC | cast to-dec
  cast call $SYSTEM_CONTRACT_ADDR "_extraGas()" --rpc-url $REACTIVE_RPC | cast to-dec
  cast call $SYSTEM_CONTRACT_ADDR "_maxChargeGas()" --rpc-url $REACTIVE_RPC | cast to-dec
  ```
  每个 callback proxy 在部署时单独配置、**无默认值**，各目标链数值不同，必须向 proxy 本人查询（同上三条，把地址和 RPC 换成 proxy / 目标链）。
- **Gas 上限**：reactive 交易 gas cap **900,000**；回调 gas limit **最低 100,000**，低于此值的回调请求会被忽略。proxy 在调用接收方前会扣掉自身记账 gas（`_extraGas`）和可能的结算 gas（`_maxChargeGas`），只把剩余部分转发；gas 给少了先报 `InsufficientGas`（方法根本没跑），够 proxy 开销但不够方法本身则方法 revert、记为 `CallbackFailure`。回调 gas limit 设在 reactive 侧，接收方反复失败时要让请求方调高 limit，而不是只充钱。

### 4.3 余额 / Reserves / Debt 三个数

| 值 | 存在哪 | 含义 |
|---|---|---|
| Balance | 合约自己身上 | 合约可花的钱 |
| Reserves | System 合约或 callback proxy | 预付的手续费额度 |
| Debt | System 合约或 callback proxy | 欠下未付的手续费 |

- 扣费先走 reserves，不够才记 debt；充值先清 debt，余下才进 reserves。合约**不会同时持有 reserves 和 debt**。
- 直接转账只增加 balance，**不产生 reserves、也不清 debt**。
- **⚠️ 任何 debt > 0 就停摆**：system 合约不调 `react()`，proxy 不投递回调。不是“余额不足才停”，而是“欠一分钱就停”。还清后发 `WhitelistContract` 事件恢复服务；欠下时发 `BlacklistContract` 事件。
- **失败也要付费**：`react()` revert 照收全费（记 `ReactiveContractReverted`）；回调失败照收全费（记 `CallbackFailure`）。唯一例外：回调目标地址**没有合约代码**，proxy 在调用前 revert `NotAContract`，不收费。

### 4.4 充值方式

**Reactive 合约（充 REACT / lREACT），二选一：**

1. 经 System 合约 `depositTo()` 充 reserves（推荐；可由任何人发起，也能救活第三方欠债合约）：
   ```bash
   cast send --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY \
     $SYSTEM_CONTRACT_ADDR "depositTo(address)" $REACTIVE_CONTRACT_ADDR --value 1ether
   ```
   ⚠️ 直接往 System 合约转 REACT 只会记到**发送者自己名下**，不是目标合约——必须走 `depositTo(目标地址)`。
2. 直接转 REACT 到 reactive 合约（只加 balance；扣费时 system 合约在同一笔交易内调合约的 `pay()` 自动结算，`pay()` 的 gas 上限为 `_maxChargeGas`，自定义 `pay()` 逻辑必须极简，超预算或余额不足会发 `PaymentFailure` 事件、债务留存）；或合约暴露 `coverDebt()` 后手动结算：
   ```solidity
   /// @notice Settles outstanding debt from this contract's own balance.
   function coverDebt() external {
       _coverDebt();
   }
   ```
   ```bash
   cast send $REACTIVE_CONTRACT_ADDR --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY --value 1ether
   cast send --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY $REACTIVE_CONTRACT_ADDR "coverDebt()"
   ```
   ⚠️ **充到欠债合约的直接转账可能被困住**：直接转账既不清 debt 也不建 reserves；如果合约没暴露 `coverDebt()`，这笔钱谁也动不了去还债，合约永久停摆。拿不准就用 `depositTo()`。

**回调合约（充目标链原生币），同理走 proxy：**
```bash
# 充 reserves
cast send --rpc-url $DESTINATION_RPC --private-key $DESTINATION_PRIVATE_KEY \
  $CALLBACK_PROXY_ADDR "depositTo(address)" $CALLBACK_CONTRACT_ADDR --value 0.1ether
# 或直接转账 + coverDebt()
cast send $CALLBACK_CONTRACT_ADDR --rpc-url $DESTINATION_RPC --private-key $DESTINATION_PRIVATE_KEY --value 0.1ether
cast send --rpc-url $DESTINATION_RPC --private-key $DESTINATION_PRIVATE_KEY $CALLBACK_CONTRACT_ADDR "coverDebt()"
```

### 4.5 到底要充多少（官方文档没有固定最低值）

- **当前版官方文档没有规定最低充值额**，费用按实际 gas × 公式实时算。能给的参考量级（均来自演示/旧资料，非官方最低标准）：
  - 官方文档 `forge create` 部署示例用 `--value 0.01ether`；basic demo 用 reactive 合约 `--value 0.1ether`、回调合约 `--value 0.02ether`；止损 demo 用 reactive `--value 0.1ether`、回调 `--value 0.02ether`。
  - Reactor（旧版无代码工具）博客建议值：reactive 合约 0.05 REACT、目标合约 0.03 ETH——**旧版博客的经验值，仅供参考**。
- 粗算 reactive 侧单次 `react()` 成本：`fee ≈ gasprice × 1.0 × (g_used + 100,000)`。`react()` 本身 gas 上限 900,000，简单逻辑一次约 100k–300k gas，则单次约 200k–400k gas 当量的 REACT；按此估算，0.1 lREACT 在 Lasna 上可支撑数十到数百次触发（以实际 gasprice 为准，部署后用 §4.6 的查询命令实测一次真实扣费再定预算）。
- 回调侧单次成本：`fee ≈ 目标链 gasprice × C_proxy × (g_used + K_proxy)`，`C`/`K` 各链 proxy 不同，部署前先查 proxy 的 `_gasPriceCoeffPer1000()` / `_extraGas()`。
- 关键是**两边都要持续有钱**：reactive 合约没钱 → 不触发；回调合约没钱/有债 → 触发了也执行不了。黑客松演示建议两边都按演示量多充（demo 级别 0.1 lREACT + 0.02 Sepolia ETH 起步），并在演示前查一次 debt/reserves。

### 4.6 查账命令

```bash
# 余额
cast balance $REACTIVE_CONTRACT_ADDR --rpc-url $REACTIVE_RPC
cast balance $CALLBACK_CONTRACT_ADDR --rpc-url $DESTINATION_RPC
# 债务（新接口 debt()；debts() 是兼容旧版的别名）
cast call $SYSTEM_CONTRACT_ADDR "debt(address)" $REACTIVE_CONTRACT_ADDR --rpc-url $REACTIVE_RPC | cast to-dec
cast call $CALLBACK_PROXY_ADDR "debt(address)" $CALLBACK_CONTRACT_ADDR --rpc-url $DESTINATION_RPC | cast to-dec
# Reserves
cast call $SYSTEM_CONTRACT_ADDR "reserves(address)" $REACTIVE_CONTRACT_ADDR --rpc-url $REACTIVE_RPC | cast to-dec
cast call $CALLBACK_PROXY_ADDR "reserves(address)" $CALLBACK_CONTRACT_ADDR --rpc-url $DESTINATION_RPC | cast to-dec
# 服务方确认（reactive 合约应返回 system 合约；回调合约应返回 proxy）
cast call $REACTIVE_CONTRACT_ADDR "_SERVICE_PROVIDER()" --rpc-url $REACTIVE_RPC
cast call $CALLBACK_CONTRACT_ADDR "_SERVICE_PROVIDER()" --rpc-url $DESTINATION_RPC
# 查某笔 reactive 交易产生的所有回调记录（按 reactive 交易哈希；空数组 = 尚未记录，不等于失败）
cast call $SYSTEM_CONTRACT_ADDR "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])" $REACTIVE_TX_HASH --rpc-url $REACTIVE_RPC
# 每条记录含：区块号、请求方 reactive 合约、该交易内回调序号、目标链 ID、目标交易哈希、err（空 = 成功）
```

### 4.7 执行流程（System 合约 `trigger()` 六步，文档配图未给文字版，行为要点）

1. 先查 debt——有债直接不执行、不花 gas（所以欠债合约是“悄悄停摆”，不是报错）。
2. 执行 `react()`。
3. 之后按实际 gas 计费；`react()` revert 也会被捕获、记事件、照常走到计费。
4. 费用（kickback）付给 `tx.origin`，即提交该笔交易的验证者。

---

## 5. 回调合约（目标链，Omni 写法）

### 5.1 最小回调合约（直接取自官方文档 Callback Contracts 页）

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

contract MyCallback is AbstractCallback {
    event Handled(address indexed reactive_, uint256 value_);

    // `payable` so the contract can be funded at deployment.
    constructor(IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
    }

    function myCallback(address reactive_, uint256 value_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        emit Handled(reactive_, value_);
    }
}
```

### 5.2 鉴权：两个 modifier 缺一不可

| Modifier | 回答的问题 | 失败时 |
|---|---|---|
| `onlyServiceProvider` | 调用者是不是该链的 callback proxy（`msg.sender == proxy`） | revert `NotAuthorized` |
| `onlyCallbackSender(reactive_)` | payload 里注入的地址是不是你授权的那一个 reactive 合约（`== _CALLBACK_SENDER`） | revert `CallbackNotAuthorized` |

- 只用第一个：任何人都能直接调你的回调方法、自己编一个 sender 地址。
- 只用第二个：任意 reactive 合约都能走合法 proxy 驱动你的回调。
- 回调方法的**第一个参数必须是 `address`**：proxy 会把 payload 前 160 位覆写为发起回调的 reactive 合约地址，不管 reactive 侧编码时填了什么（填 `address(0)` 占位）。参数名随意，类型和位置才重要；把它原样传给 `onlyCallbackSender`，需要时也用作 sender 身份。
- 构造函数两个参数都存为 immutable，**部署后不可改**：`callbackProxy_`（该链 proxy 地址，见 §2）成为扣费服务方；`callbackSender_`（授权的 reactive 合约地址）写错就只能重新部署。
- 继承 `AbstractCallback` 不是强制的：任何签名匹配的合约都会收到调用，但那样既无鉴权、也无付费能力——会接受伪造调用并欠下还不清的债。
- **一个合约不能同时是 reactive 合约和回调合约**：`AbstractPayer` 只有一个 immutable `_SERVICE_PROVIDER`，`AbstractReactive` 把它写死为 `SYSTEM`，`AbstractCallback` 写死为 proxy，两边一起继承编译不过。reactive 合约想回调自己（`chainId: block.chainid, recipient: address(this)`）时，要手写 `msg.sender` + 注入地址的检查。
- proxy 调用前会检查目标地址有代码，否则 revert `NotAContract`，且不收费。
- 回调计费细节见 §4：回调由接收方付目标链原生币；失败也收费；proxy 转发的 gas 要扣掉自身开销，limit 设小了会 `InsufficientGas`。

### 5.3 部署顺序（循环依赖的解法）

1. 先部署 reactive 合约。
2. 再部署回调合约，构造函数传 callback proxy 地址 + reactive 合约地址。
3. 通过 reactive 合约的 owner-only setter 设置 recipient（回调合约地址）。
4. 两边都充钱：reactive 合约充 REACT/lREACT，回调合约充目标链原生币。

---

## 6. Omni vs Legacy：写新合约必须用的改法

| 变化点 | Legacy（旧） | Omni（新，当前文档） |
|---|---|---|
| `vm` modifier / RVM 双状态 | 有（`if (!vm)` 包订阅，`react() external vmOnly`） | **删掉**：reactive 合约就是普通合约，无 RVM |
| 订阅调用 | `service.subscribe(...)`，service 在 `0x000…fffFfF` | `SYSTEM.subscribe(...)`，`SYSTEM = 0x8888…8888` |
| `react()` 签名 | `react(LogRecord calldata log) external vmOnly` | `react(LogRecord memory log_) external onlySystem` |
| 回调请求 | `emit Callback(destChainId, callback, gasLimit, payload)` | `SYSTEM.requestCallbackV_1_0(CallbackConfiguration_V_1_0({...}))` |
| 回调鉴权 | 旧 `authorizedSenderOnly` / `rnOnly` 等 | `onlyServiceProvider` + `onlyCallbackSender(addr)` |
| LogRecord 字段名 | 蛇形：`log._contract`、`log.chain_id`、`log.topic_0` | 驼峰：`log.contractAddress`、`log.chainId`、`log.topic0` |
| System 合约地址 | `0x0000000000000000000000000000000000fffFfF`（现仅用于发 Cron 事件） | `0x8888888888888888888888888888888888888888` |
| 工具 | 专用 RPC 方法模拟 RVM 执行、看 trace | 已删除；标准 EVM 链，`cast`/Foundry 直接用 |
| 依赖库 | `reactive-lib`（`src/abstract-base/AbstractReactive.sol`） | **`reactive-lib-omni`**（`src/base/AbstractReactive.sol`） |

Getting Started 页的 ping/pong 迁移示例（`PING_TOPIC_0` / `pong(address,address)`）就是按上表改的，但**官方文档里没有给 ping/pong 的完整独立 demo 仓库**，它只是个代码片段；最小可跑的端到端例子用 §7 的 Basic Demo。

---

## 7. 官方示例仓库与关键代码

### 7.1 核心库（Omni，写合约时 import 的来源）

- **https://github.com/Reactive-Network/reactive-lib-omni** — Omni 版 reactive 库（`@reactive`）。关键文件：
  - `src/base/AbstractReactive.sol` — `SYSTEM`、`REACTIVE_IGNORE`（`0xa65f96fc…12313ad`）、`onlySystem`
  - `src/base/AbstractCallback.sol` — `AbstractCallback(IPayable callbackProxy_, address callbackSender_)`、`_CALLBACK_SENDER`、`onlyCallbackSender`
  - `src/base/AbstractPayer.sol` — `pay()`、`_coverDebt()`、`receive()`
  - `src/interfaces/ISystemContract.sol` — `CallbackVersion`、`CallbackConfiguration_V_1_0`、`requestCallback` / `requestCallbackV_1_0`
  - `src/interfaces/ISubscriptionService.sol` — `subscribe` / `unsubscribe` 六参数签名
  - `src/interfaces/IReactive.sol` — `LogRecord` 结构体与 `react()` 声明

### 7.2 官方演示仓库

- **https://github.com/Reactive-Network/reactive-smart-contract-demos** — 官方 demo 合集（README 在 `dev.reactive.network/legacy/demos` 有索引）。
- **Basic Demo（最小端到端，优先看）**：`src/demos/basic/` — origin 链合约发 `Received` 事件 → reactive 合约订阅，`react()` 里判 `value >= 0.001 ETH`（`topic_3`）→ 回调目标链合约。含部署脚本与 topic0：`Received` 事件签名哈希 `0x8cabf31d2b1b11ba52dbb302817a3c9c83e4b2a5194d35121ab1354d69f6a4cb`。部署时 reactive 合约 `--value 0.1ether`、回调合约 `--value 0.02ether`。
- **Uniswap V2 Stop Order Demo**：`src/demos/uniswap-v2-stop-order/` — 单向止损。reactive 合约订阅 Uniswap pair 的 `Sync` 事件。
- **Uniswap V2 Stop-Loss & Take-Profit Demo（与本赛道最相关）**：`src/demos/uniswap-v2-stop-take-profit-order/` — 每用户独立部署一套，支持止损和止盈两种方向。详见 §8。
- 其他 demo：Aave Liquidation Protection（CRON 触发健康因子检查，低于阈值回调补仓/还款）、Leverage Loop、Automated Prediction Market、Gasless Cross-Chain Atomic Swap、Approval Magic、Hyperlane、CRON Demo。
- 另有社区/参赛参考（非官方仓库，仅作思路对照）：DoraHacks 上的 **Reactive Limit Orders**（`https://github.com/sawi57003-ops/reactive-limit-orders`，Unichain Sepolia 上 `LimitOrderRegistry` + Lasna 上 `LimitOrderReactive`，订阅价格 feed 事件、触发后回调执行；demo 里用 MockPriceFeed + demo AMM，生产应换真实 Chainlink feed 与 Uniswap v4）和 **Sentinel**（Lasna 上 `AnomalySentinel`，`react()` 内跑链上神经网络判异常）。

### 7.3 止损 demo 的关键逻辑（可直接复用的模式）

**价格来源：Uniswap V2 pair 的 `Sync` 事件**，不依赖外部预言机（demo 做法；生产可用 Chainlink/Pyth feed 事件替代触发源，执行价仍以 AMM 为准）：

```solidity
uint256 private constant UNISWAP_V2_SYNC_TOPIC_0 =
    0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;

struct Reserves { uint112 reserve0; uint112 reserve1; }
```

**react() 内逐单比价（止损 demo，`UniswapDemoStopTakeProfitReactive.sol`）**：

```solidity
// Sync 事件的 data 就是 Reserves（reserve0, reserve1）
Reserves memory reserves = abi.decode(log.data, (Reserves));

// 当前价 = reserve1 * coefficient / reserve0（卖 token0 时；反向则倒过来），用 mulDiv 防溢出
uint256 currentPrice = Math.mulDiv(uint256(reserves.reserve1), coefficient, uint256(reserves.reserve0));

if (orderType == OrderType.StopLoss) {
    return currentPrice <= threshold; // 跌破阈值执行
} else {
    return currentPrice >= threshold; // 涨过阈值执行
}
```

**订单模型要点（止损 demo 的做法，值得照搬）：**
- 订单在**目标链回调合约**上创建：`createStopOrder(pair, sellToken0, amount, coefficient, threshold, orderType)`，其中 `orderType: 0 = 止损，1 = 止盈`；coefficient 通常取 `10000`（4 位小数精度），如阈值 0.8 写 `8000`、1.2 写 `12000`。
- reactive 合约订阅回调合约的 5 个生命周期事件：`StopOrderCreated` / `StopOrderCancelled` / `StopOrderExecuted` / `StopOrderPaused` / `StopOrderResumed`；新建订单时才动态订阅该 pair 的 `Sync`，订单全部完成/取消后退订（省 gas、省触发费）。
- 触发保护：**冷却 5 分钟**（`TRIGGER_COOLDOWN = 300`，同一订单两次触发至少间隔 300 秒）+ **最多 5 次尝试**（`MAX_TRIGGER_ATTEMPTS = 5`，超限订单标 `Failed`），防止失败回调反复扣费。
- 回调执行时目标链合约**链上二次验价**（防过期触发），再 `transferFrom` 用户已授权的 token、走 Uniswap V2 Router 换币、把所得还给用户；回调合约继承 `RescuableBase`，owner 可救回卡住的 ETH/token。
- 订单可随时 pause / resume / cancel（按 orderId，从 0 开始）。
- 触发回调的 payload 示例：`abi.encodeWithSignature("executeStopOrder(address,uint256)", address(0), orderId)`，gas limit 1,000,000。
- 简化版止损 demo（`uniswap-v2-stop-order`）的单订单写法：`below_threshold` 用 `(reserve1 * coefficient) / reserve0 <= threshold`（卖 token0 时），触发后 `stop(address,address,address,bool,uint256,uint256)` 回调执行 swap。

**价格监控的另一条官方路线（Pyth feed 事件，见 Reactive 博客 Maestro 项目）：** reactive 合约订阅 Pyth 的 `PriceFeedUpdate` 事件并按 `priceId` 过滤（topic1 = 具体 feed 的 ID），`react()` 里取出新价格再回调到目标链。Chainlink feed 本身不发事件，**不能直接订阅 Chainlink**；要监听价格变化，要么订阅 Uniswap pair `Sync`，要么订阅 Pyth 这类会发事件的 feed，要么用 CRON 定时触发后在 `react()` 里读链上价格（CRON 每次 tick 都收费）。

---

## 8. 部署流程（Foundry cast / forge，Lasna）

### 8.1 环境变量（按官方 demo README）

```bash
export REACTIVE_RPC=https://lasna-rpc.rnk.dev/
export REACTIVE_PRIVATE_KEY=<lasna 部署私钥>
export DESTINATION_RPC=<目标链 RPC，如 Sepolia>
export DESTINATION_PRIVATE_KEY=<目标链部署私钥>
export DESTINATION_CALLBACK_PROXY_ADDR=<目标链 proxy 地址，见 §2，如 Sepolia 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4>
export USER_WALLET=<部署者 EOA 地址>
```

### 8.2 部署顺序与命令（以止损 demo 为例）

```bash
# 1. （如需）部署测试 token / 建 Uniswap V2 pair / 加流动性（见 demo README Step 1–3）
# 2. 部署回调合约（目标链），--value 充原生币；构造参数：用户钱包、proxy 地址、Uniswap V2 Router
forge create --broadcast --rpc-url $DESTINATION_RPC --private-key $DESTINATION_PRIVATE_KEY \
  src/demos/uniswap-v2-stop-take-profit-order/UniswapDemoStopTakeProfitCallback.sol:UniswapDemoStopTakeProfitCallback \
  --value 0.02ether --constructor-args $USER_WALLET $DESTINATION_CALLBACK_PROXY_ADDR 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008
# 记下 Deployed to → CALLBACK_ADDR

# 3. 部署 reactive 合约（Lasna），--value 充 lREACT；构造参数：用户钱包、回调合约地址
forge create --broadcast --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY \
  src/demos/uniswap-v2-stop-take-profit-order/UniswapDemoStopTakeProfitReactive.sol:UniswapDemoStopTakeProfitReactive \
  --value 0.1ether --constructor-args $USER_WALLET $CALLBACK_ADDR
# 记下 Deployed to → REACTIVE_ADDR

# 4. 用户授权回调合约花自己的 token（例：授权 1 个 token）
cast send $TOKEN0 'approve(address,uint256)' --rpc-url $DESTINATION_RPC \
  --private-key $DESTINATION_PRIVATE_KEY $CALLBACK_ADDR 1000000000000000000

# 5. 创建止损单：卖 1 个 token0，价格跌到 0.8 时执行（coefficient 10000，threshold 8000，type 0=止损）
cast send $CALLBACK_ADDR 'createStopOrder(address,bool,uint256,uint256,uint256,uint8)' \
  --rpc-url $DESTINATION_RPC --private-key $DESTINATION_PRIVATE_KEY \
  $UNISWAP_V2_PAIR_ADDR true 1000000000000000000 10000 8000 0

# 止盈单：同样参数，threshold 12000、type 1
cast send $CALLBACK_ADDR 'createStopOrder(address,bool,uint256,uint256,uint256,uint8)' \
  --rpc-url $DESTINATION_RPC --private-key $DESTINATION_PRIVATE_KEY \
  $UNISWAP_V2_PAIR_ADDR true 1000000000000000000 10000 12000 1
```

### 8.3 通用部署命令（官方文档 Reactive Contracts 页）

```bash
forge create \
  --broadcast \
  --rpc-url $RPC_URL \
  --verifier sourcify \
  --verify \
  --chain-id $CHAIN_ID \
  --private-key $PRIVATE_KEY \
  --value 0.01ether \
  src/.../MyContract.sol:MyContract \
  --constructor-args $ARGUMENT_1 $ARGUMENT_2 $ARGUMENT_3
# $CHAIN_ID：1597（主网）或 5318007（Lasna）
# $RPC_URL：https://mainnet-rpc.rnk.dev/ 或 https://lasna-rpc.rnk.dev/
# 合约验证走 Sourcify；部署后验证：
forge verify-contract --verifier sourcify --chain-id $CHAIN_ID $CONTRACT_ADDR $CONTRACT_NAME
```

### 8.4 注意事项

- **reactive 合约的构造函数必须是 `payable`** 才能在部署时 `--value` 充值；基类本身的构造函数不是 payable，不写 `payable` 时 `--value` 部署会 revert。
- 旧版 Foundry 不支持 `forge create --broadcast`（报错 `unexpected argument '--broadcast'`），去掉该 flag 再跑。
- 部署顺序不能反：回调合约构造时就要 reactive 合约地址；reactive 合约的 recipient 用 owner-only setter 事后设置（§5.3）。
- **先充钱再等事件**：reactive 合约在第一个匹配事件到达前就必须有资金（reserves 或 balance），否则直接欠债停摆；回调合约同理。
- Token 顺序按地址大小定：地址较小的 token 是 `token0`。
- 测试触发：直接对 pair 做一笔 swap 改价，reactive 合约会检测到并执行已越阈值的订单；在 Sepolia 浏览器上核对执行结果。
- 合约状态与回调记录：Reactscan（lasna.reactscan.net）查合约状态；`getCallbacks` 按 reactive 交易哈希查回调投递结果（§4.6）。
- 不要把主网和测试网 origin/destination 混用；Lasna 演示用 Sepolia / Base Sepolia / Unichain Sepolia 做 origin/destination。

---

## 9. 文档矛盾与注意事项（以最新版文档为准）

1. **演示仓库仍是 Legacy 写法，与当前 Omni 文档冲突**。`reactive-smart-contract-demos`（main 分支，2026-11-18 抓取时）全部使用旧版模式：`if (!vm)` 包订阅、`react(LogRecord calldata log) external vmOnly`、`emit Callback(...)`、`service.subscribe`、`authorizedSenderOnly` / `rnOnly`、LogRecord 蛇形字段（`log._contract` / `log.chain_id` / `log.topic_0`）。**新项目不要照抄这些 demo 的 reactive 合约写法**；只借鉴其业务逻辑（Sync 比价、订单状态机、冷却/重试、回调二次验价），合约骨架按本文 §3/§5 的 Omni 写法（`SYSTEM.subscribe` + `requestCallbackV_1_0` + `onlySystem` + `onlyServiceProvider`/`onlyCallbackSender`）重写。官方文档的 Demos 页本身也放在 `/legacy/demos` 路径下。
2. **止损 demo 源码里的 chain ID 注释有误**：`UniswapDemoStopTakeProfitReactive.sol` 中 `SEPOLIA_CHAIN_ID = 1`（1 是以太坊主网，Sepolia 应为 11155111），且 `REACTIVE_CHAIN_ID = 1597` 旁注释写着 “Lasna network chain ID”（1597 是 Reactive 主网，Lasna 是 5318007）。以本文 §1/§2 的官方文档数值为准（Sepolia 11155111、Lasna 5318007、主网 1597）。
3. **费用无官方最低值**：当前版 Economy 文档只给公式和默认值，不规定“最少充多少 REACT”。§4.5 的 0.1 lREACT / 0.02 ETH 是 demo 的部署充值量，0.05 REACT / 0.03 ETH 是旧版 Reactor 博客的经验值，都不是官方最低标准；正式预算以部署后实测的一次真实扣费为准。
4. **水龙头表述**：文档 Mainnet/Testnet 页写 “1 ETH → 100 lREACT”，demo README 写 “100 REACT per 1 SepETH”，两者一致（测试网币就是 lREACT），不是矛盾。
5. **旧版 `emit Callback` 仍可用但已废弃**：新合约用 `requestCallbackV_1_0`；只有维护旧合约时才需要知道旧事件方式。
6. **Chainlink 不能直接订阅**：Chainlink 价格 feed 本身不发事件，文档和 demo 里都没有“订阅 Chainlink”的做法；价格触发源用 Uniswap `Sync`、Pyth `PriceFeedUpdate` 事件，或 CRON 定时触发（后者按 tick 收费）。
7. **回调 gas limit 不要只按方法本身估算**：proxy 会先扣 `_extraGas` 与 `_maxChargeGas`，官方 demo 统一用 1,000,000；低于 100,000 的请求会被直接忽略。
8. **官方文档未覆盖的内容**：Lasna 上没有网页版水龙头（只有转 ETH 到合约）；没有给出各目标链 proxy 的 `_gasPriceCoeffPer1000` / `_extraGas` 具体数值（须链上现查）；没有给出 Sepolia Chainlink/Pyth feed 的官方合约地址；没有给出“Set It and Forget It”赛道的官方 ping/pong 独立示例仓库（ping/pong 只出现在 Getting Started 的迁移代码片段中）。

---

## 10. 来源清单

- 文档首页 / Omni 迁移说明：https://dev.reactive.network/
- Reactive Contracts：https://dev.reactive.network/reactive-contracts
- Callback Contracts：https://dev.reactive.network/callback-contracts
- Economy & System Interactions：https://dev.reactive.network/economy
- Reactive Mainnet & Lasna Testnet：https://dev.reactive.network/reactive-mainnet
- Origins & Destinations（含全部 callback proxy 地址）：https://dev.reactive.network/origins-and-destinations
- Demos 索引（legacy）：https://dev.reactive.network/legacy/demos
- Omni 核心库：https://github.com/Reactive-Network/reactive-lib-omni
  - `src/base/AbstractReactive.sol`（`REACTIVE_IGNORE` 值、`SYSTEM` 地址）
  - `src/base/AbstractCallback.sol`（`onlyCallbackSender`、`_CALLBACK_SENDER`）
  - `src/interfaces/ISystemContract.sol`（`CallbackConfiguration_V_1_0`、`requestCallbackV_1_0`）
  - `src/interfaces/ISubscriptionService.sol`（`subscribe` / `unsubscribe`）
- 官方 demo 仓库：https://github.com/Reactive-Network/reactive-smart-contract-demos
  - `src/demos/basic/`（最小端到端）
  - `src/demos/uniswap-v2-stop-order/`（单向止损）
  - `src/demos/uniswap-v2-stop-take-profit-order/`（止损 + 止盈，含完整部署 README）
- 参考（非官方）：Reactive Limit Orders（DoraHacks 参赛项目）：https://github.com/sawi57003-ops/reactive-limit-orders
