# 幻兽帕鲁自动拾取

[English](README.md) | 中文

这是一个用于 Palworld Steam 版的服务端 UE4SS Lua Mod。帕鲁被击杀后，该帕鲁通过游戏原生死亡掉落流程产生的掉落物，会自动由击杀者玩家拾取。

## 行为范围

- 只处理帕鲁死亡掉落流程产生的掉落物。
- 支持人物击杀、骑乘时人物击杀、未骑乘召唤帕鲁击杀、骑乘帕鲁击杀，只要攻击者能解析回玩家。
- 使用 Palworld 原生拾取请求路径，背包容量、重量、权限和同步仍由游戏处理。
- 失败时保持关闭策略：无法确认来源属于已验证帕鲁死亡上下文的掉落物，一律留在世界中。
- 不会自动拾取挖矿、砍树、采集、宝箱、玩家丢弃物或人形 NPC 掉落。

## 安装

先为目标 Palworld Steam 版本安装可用的 UE4SS，然后把本仓库中的 `AutomaticPickup` 文件夹放到：

```text
Pal/Binaries/Win64/ue4ss/Mods/AutomaticPickup
```

期望目录结构：

```text
AutomaticPickup/
  enabled.txt
  Scripts/
    config.lua
    main.lua
```

多人专用服务器只需要在服务器安装 UE4SS 和本 Mod。客户端不需要安装，背包更新走服务端原生拾取流程。

UE4SS 请使用与当前 Palworld Steam 版本兼容的构建，不建议固定使用旧的通用版本。

## 配置

编辑 `AutomaticPickup/Scripts/config.lua`。

- `ENABLED`：开启或关闭 Mod。
- `STRICT_SOURCE_BINDING`：限制只拾取已验证的帕鲁死亡掉落，正常使用应保持开启。
- `DEBUG_SOURCE_BINDING`：输出死亡上下文、掉落绑定和忽略原因。
- `ASYNC_BIND_WINDOW_SECONDS`：死亡 hook 返回后，允许原生掉落物稍后创建的短时间窗口。
- `ASYNC_BIND_RADIUS`：仅在已验证帕鲁死亡上下文内使用的位置兜底半径。
- `PICKUP_DELAY_MS`：掉落物可交互后，请求原生拾取前的延迟。

## 日志

UE4SS 日志位置：

```text
Pal/Binaries/Win64/ue4ss/UE4SS.log
```

验证新 Palworld 或 UE4SS 版本时，可以开启 `DEBUG_SOURCE_BINDING`。重点查看 `opened death context`、`bound drop model`、`requested pickup for player id` 等日志。

## 兼容性说明

本 Mod 不复制、不重写 Palworld 的掉落表。掉落概率、掉落数量、世界设置、背包限制和拾取权限都保持游戏原生逻辑。

如果 Palworld 改动死亡掉落或地图物体生命周期，Mod 可能需要小范围更新 hook。当前兜底逻辑刻意保守，目的是避免拾取无关的世界掉落物。
