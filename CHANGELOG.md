# 更新记录

这个仓库是 [yangyihang96/CoCanBar](https://github.com/yangyihang96/CoCanBar) 的衍生版，分叉点是上游的
`b5ab162`（2026-10-27）。下面只记这里改了什么，上游的历史不搬。

`0.2.0` 的这些改动同时提了 [PR #3](https://github.com/yangyihang96/CoCanBar/pull/3) 给上游，还开着、还等回复。
在这个仓库里单独发版，是因为不想让自己的使用体验卡在别人的时间表上，不代表放弃合并——
上游如果合了，这边的差异就只剩取色值，到时候按最后一节的办法合并即可。

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号用
[语义化版本](https://semver.org/lang/zh-CN/)。上游没有发布过带版本号的 release，
所以 `0.1.0` 是上游的最后一个状态，衍生版的改动从 `0.2.0` 起算。

## [0.2.0] — 2026-10-28

相对上游 `b5ab162`。

### 新增

- **冷色调配色**，和原来的暖色一键切换。原来的奶油底加橙红偏刺眼，深色外观下尤其明显。
  - 冷色取值：底 `#F0F4F9` / `#141920`，卡片 `#FFFFFF` / `#1E242C`，强调色 `#2F7BF6`，
    端口功率弧线从浅青到深蓝。暖色的数值保持原样没动。
  - 切换入口两处：设置「通用 → 外观 → 冷色调」开关，面板齿轮菜单里的「换成冷色调 / 暖色调」。
  - 选择写进 App Group 容器的 `theme.txt`，桌面小组件每次画之前重新读盘，
    所以 app 没运行时小组件自己读设备，配色也是对的。
  - 调试参数 `--theme warm|cool`：这次运行用指定配色，不写盘。
- **6 项配色单元测试**（`Tests/CoCanKitTests/ThemeTests.swift`）。测的是约定不是具体色值：
  强调色和底色必须跟着主题换；四套场景配色都跟着换、五个口一个不少；状态色换主题后色相不能跑偏；
  冷色的强调色是蓝的，状态色要和它拉开距离；`theme.txt` 能来回读；存的值认不出来时回到暖色而不是崩。
  `Color` 不可比较，用 `NSColor` 转 sRGB 分量再比，色相用色相环上的最短距离。
  测试目标因此加上对 `CoCanStyle` 的依赖。
- `scripts/build-app-local.sh`：`build-app.sh` 的只编当前架构版本。
  通用构建在这台机器上会撞 Swift 宏插件报错，自用可以只编 arm64。
- `Support/AppIconCool.icns`：蓝色渐变的 app 图标，给冷色调时的面板头部用。Finder 里始终是暖色那版。

### 改动

- **菜单栏图标**从 SF Symbol 的闪电换成制糖工厂官网的糖标，和 app 图标统一。
  - 标志从官网 SVG 转成 CGPath（`Sources/CoCanBar/CandyMark.swift`），没有运行时依赖，
    菜单栏、面板左上角、app 图标三处用的是同一条路径。
  - 糖高按字高的 0.85 倍，宽度按标志的固定比例。在线实心、离线描边。
  - 读数去掉「W」后，宽度样本改成 `88.8 / 999 / 1.2k / —`，宽度仍然固定，
    读数变化时图标不会左右挪。界面上不写单位，读屏时补「瓦」。
- **app 图标**重做成圆角方块加白标志，生成器 `scripts/make-app-icon.swift`，
  字体和边界处理在 RGBA 上软件渲染，不依赖窗口服务器。
- `Palette` 的成员改成按当前配色取值的 computed var，名字一个没改，原来约 90 处调用不用动。
  `ThemeMode`（warm / cool）+ `Theme`（一套 token 的结构体）+ `ThemeStorage`。
- 状态色（温度、在线、危险）只跟着底色微调明暗，色相不变。
  温度从凉到热必须是绿-黄-红，跟着强调色挪成蓝色会读成「凉快」。
  冷色实际的微调：在线 `#00C539`→`#10B981`、危险 `#FF3B30`→`#E5484D`、
  偏热 `#FFA51E`→`#F5A524`、过热 `#FF4719`→`#E8562B`。
- 面板、设置窗口、桌面小组件三种尺寸都跟着换配色，「调节」页画的机身颜色也跟。
- README 补图标和两套配色的说明，`--theme` 参数写进调试一节。

### 没有动

- `scripts/make-icon.swift` 和 `Support/AppIcon-source.png` 已经不再被引用，但没有删。
  上游的文件，删不删留给上游决定。
- app 名字和 bundle id 保持 `com.local.CoCanBar` 没改，所以和上游版本不能同时装。

### 验证

- `swift test --disable-sandbox`：82 项全过（原有 76 项 + 新增 6 项）。
- 本机 macOS 26 / Xcode 27.1，打包签名后装到 `/Applications` 跑过一次，
  面板读数、小组件共享数据、两套配色切换都正常。
- 没有屏幕录制权限，界面是离屏渲染核对（面板 7 个场景 × 浅深两色、小组件 58 张）。

## 怎么跟上游同步

这个仓库不会自动跟上游。上游更新后手动合：

```bash
git remote add upstream https://github.com/yangyihang96/CoCanBar.git   # 只需一次
git fetch upstream
git log --oneline main..upstream/main        # 看上游多出什么
git merge upstream/main                      # 冲突基本只会出在 README 和 Style.swift
```

冲突集中在两处是正常的：README 加了衍生说明的段落，`Style.swift` 的 `Palette` 从常量改成了 computed var。
上游如果也把配色重构了，以哪套结构为准得自己判断一次。

如果上游哪天合并了同样的改动，把对应的 `CHANGELOG` 条目划掉、换成「已在上游」即可，
代码不用回退——两边的实现大概率会一致，剩下的差异只有取色值。

[0.2.0]: https://github.com/hwisdom-jpg/CoCanBar/releases/tag/v0.2.0
