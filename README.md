# 迈世通泵 iOS 独立打药 App

从 AAPS 的 `plugins/pump/demose`（迈世通 / MedNovo）驱动移植出来的独立 iOS App，
只做一件事：用 iPhone 直连迈世通胰岛素泵，看状态、打大剂量、设 TBR、停止输注。

## 一、先说清楚（务必阅读）

- **未签名 IPA**：只能通过 Sideloadly / AltStore / TrollStore 等工具自签安装，需要你自己的 Apple ID。
- **不是医疗器械**：这是逆向移植的个人工具，没有做过任何临床验证。**首次使用请务必用极小剂量（0.1–0.5 U）在体外（对着试纸/空打）验证泵确实按指令动作，再考虑真机注射。**
- App 内所有安全上限（单次 10 U、TBR 200%）只是软件层护栏，**泵自身的参数限制仍需在泵上确认**。

## 二、协议要点（逆向结论）

AAPS 里那套 SATL（Twofish + RSA + 17 步握手）在该泵上**是死代码**：

- `BGP.dw()` / `MDCS.sendCancelBolusDelivering()` 都是 `cel.sendMessage(ABytes.serialize())`，明文应用层帧直接写 BLE
- `MDCS.oc()`（通知开启成功）直接 `setPaired(true)` → `CONNECTED`，没有握手
- `KeyRequest` / `deriveKeys` / `decryptRSA` 全仓无调用点

所以链路是：**GATT 连接 → 开 FFE4 通知 → 发明文帧**。

### BLE 参数

| 用途 | UUID |
|---|---|
| 读服务 | `0000FFE0-0000-1000-8000-00805F9B34FB` |
| 通知特征 | `0000FFE4-...`（CCCD `00002902-...`） |
| 写服务 | `0000FFE5-...` |
| 写特征 | `0000FFE9-...`（Write With Response） |

设备名正则：`^IP\d[\.-]`（例如 `IP4-1234567`）

### 应用层帧

```
0x55 | len(u16LE, 整帧字节数) | rw(0xA1 写 / 0xA3 读) | cmd(u16LE)
     | serial(12B ASCII，通常= 泵蓝牙名) | payload | 0x01 | msgId(u16LE) | crc16(u16LE)
```

- `len = payload.count + 23`
- CRC 覆盖 **CRC 之前的全部字节**，算法 CRC-16/MODBUS（init 0xFFFF，poly 0xA001，无 xorout）

### 命令表

| cmd | 方向 | payload |
|---|---|---|
| `0xAA02` | 写 | 大剂量 u16 = U × 10；取消大剂量传 0 |
| `0xAA03` | 写 | `0 | (分钟/15) | (百分比/10)`；取消 TBR 时长传 0 |
| `0xAA04` | 写 | 年(后两位) | 月 | 日 | 时 | 分 | 秒 |
| `0xAA05` | 写 | u16 start(U×10) | u16 时长(min) | u16 U×10；取消时 start=1 |
| `0xAA06` | 写 | `0` 启动输注 / `1` 停止输注 |
| `0xAA00` | 写 | 48 × u16，基础率 U/h × 100 |
| `0xAA00` | 读 | 空 → 回收 83 字节全状态 |
| `0x0001/0x0002/0x0003/0x0004` | 读 | 最近大剂量 / 最近基础率 / 报警 / 排气 |

应答码：`0xAA55` 接受、`0xAA5A` 参数错误、`0xAAA0` 执行中、`0xAAAA` 已执行、`0xAAA5` 拒绝。

### 全状态 `GPFSRp` 字段顺序

跳过 13 字节前导（12 serial + 1 服务字节）后依次：
`sysflag | errflag | drugLevel | ucBolusLtd | baseSegs | tBaseRate | tbaseMode | pBolusTime |
timeOffset(i8) | pulseTime | pBolusTBAK | tdinnerAlm | tcetangAlm | insulinCOEF | choCOEF |
targetBlood | lcdContrast | motoAlarmClass | bleRstatus | maxBase(u16) | boxVolume(u16/10) |
bolus3(8B) | tBaseTime | pulseBolus | dayTotaled(u16/10) | maxBolus | infuseTime | restBolus |
uiLowVolume | pulseRef | maxDaily | (8B skip) | battery 档位(1..4 → 25/50/75/100%)`

## 三、构建 / 出包

```
brew install xcodegen
xcodegen generate
xcodebuild build -project MstPump.xcodeproj -scheme MstPump \
  -sdk iphoneos -configuration Release \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
# 把 build/Build/Products/Release-iphoneos/MstPump.app 放进 Payload/ 再 zip → .ipa
```

CI：`.github/workflows/build.yml`（`workflow_dispatch` 可传 `runner_label`），
`scripts/mac_poller.py` 会自动轮换 `macos-15/14/13` 抢空闲机器、排队超时自动取消重试、成功后自动下载 IPA 到 `out/`。

## 四、安装

1. 电脑装 [Sideloadly](https://sideloadly.io/)（Win/Mac 都行），iPhone 用数据线连上
2. 把 `MstPump-unsigned.ipa` 拖进 Sideloadly，填你的 Apple ID（免费账号即可）
3. iPhone 上：设置 → 通用 → VPN与设备管理 → 信任你的开发者证书
4. 打开 App → 设置 → 允许「蓝牙」→ 回 App 点「扫描泵」
5. 免费账号签名 **7 天过期**，到期用同样步骤重签一次

## 五、代码结构

```
Sources/PumpKit/Protocol/ByteBuf.swift      # 对齐 Java ByteBuf 的小端读写
Sources/PumpKit/Protocol/CRC16.swift        # CRC-16/MODBUS
Sources/PumpKit/Protocol/AppFrame.swift     # 应用层帧编解码
Sources/PumpKit/Protocol/PumpCommands.swift # 各命令 payload + 全状态解析
Sources/PumpKit/Crypto/Twofish.swift        # SATL 遗产（当前链路用不到，保留备用）
Sources/App/PumpLink.swift                  # CoreBluetooth 链路（等价 CEL+MDCS+BGP）
Sources/App/MstPumpApp.swift                # SwiftUI 界面（含安全上限）
Tests/PumpKitTests/                         # 13 个单测：Twofish/CRC/帧/状态
```

## 六、已知风险 / 待验证

- **BLE 配对**：Android 侧允许 `setBondingAllowed(true)`，iOS 首次写入可能弹系统配对框；若报 `insufficient authentication`，先在系统蓝牙设置里完成配对再回 App
- **写入长度**：Android 请求 MTU 251；iOS 用 Write With Response 由系统自动分段，但泵是否接受长写未验证（119 字节的基础率模板风险最高）
- **未验证命令**：方波大剂量、基础率模板、排气——代码里有，但没在真机上验证过，别急着用
- **状态帧前导**：13 字节前导含义未完全确认（12 serial + 1 服务字节），字段偏移若有 1 字节偏差，读数会整体错位——**第一次连上请对照泵屏幕核对电量/药量**
