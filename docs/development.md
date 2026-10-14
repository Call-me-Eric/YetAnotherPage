# 开发者手册

这份手册说明**当前代码怎么工作**，以及**改它时哪些约束不能破**。产品想做成什么样见 [idea.md](../idea.md)，还没排进实现的阶段见 [schedule.md](../schedule.md)，用户视角见 [Readme.md](../Readme.md)。

下面每一条都对应当前仓库里的代码；函数名、常量名都是真的，可以直接搜。

## 1. 工程概况

Flutter 应用。包名 `yet_another_page`，组织标识 `dev.yetanotherpage`，macOS 的 bundle id 是 `dev.yetanotherpage.yetAnotherPage`，Android 的 namespace 与 applicationId 是 `dev.yetanotherpage.yet_another_page`。笔记目录后缀 `.yep`，当前磁盘格式版本 `formatVersion = 1`。

目标平台从第一天起就是 macOS、iOS、Android、Windows、Linux，界面只有一套。iOS 和 Android 的平台上还有笔要接，所以平板是笔的验收设备；电脑端用鼠标画，不单独打磨窗口和快捷键。

```text
lib/main.dart                       入口：接上侧键通道，打开库目录
lib/src/ids.dart                    newId()，UUID v4
lib/src/paper.dart                  格式版本、A4 尺寸、默认图层名
lib/src/ink/stroke.dart             笔画模型、采样、因果绘制、拟合、绘制
lib/src/ink/eraser.dart             工具枚举、两种橡皮的命中与裁切
lib/src/ink/text_box.dart           文字框模型
lib/src/input/stylus_side_button.dart  跨平台侧键接口与方法通道
lib/src/storage/atomic_file.dart    原子写
lib/src/storage/note_document.dart  清单、页、层、摘要、OpenNote
lib/src/storage/vault.dart          NoteLibrary 接口与 Vault 实现
lib/src/ui/library_page.dart        笔记库列表与打开笔记的过场
lib/src/ui/note_page.dart           笔记页面的状态、手势、撤销、文字框编排
lib/src/ui/page_canvas.dart         画布：InteractiveViewer、瓦片、实时墨迹
lib/src/ui/text_box_view.dart       文字框渲染与 Markdown 配置
lib/src/ui/markdown_math.dart       公式（LaTeX）渲染
lib/src/ui/layer_panel.dart         图层面板
lib/src/ui/tool_arc.dart            圆弧工具栏
lib/src/ui/title_dialog.dart        标题输入与确认对话框
ios/Runner/AppDelegate.swift        Apple Pencil 捏笔 → 侧键通道
test/                               笔画、橡皮、库、文字、界面
```

依赖故意保持很少：`path_provider`（找应用支持目录），以及文字渲染用的 `markdown_widget`、`markdown`、`flutter_math_fork`。没有状态管理库、没有数据库、没有第三方墨水/画布库。不要为了画笔引入 PencilKit 或别的墨水格式。

`analysis_options.yaml` 用 `flutter_lints`，并把 `build/`、`android/`、`ios/`、`windows/`、`macos/`、`linux/` 排除在分析之外。

常用命令：

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

笔记库在应用支持目录下的 `vault/`（`lib/main.dart` 的 `_vaultDirectory`）。iOS 的调试包必须从 `flutter run` 启动，不能从主屏幕点开。

## 2. 数据与画布分开

页面、图层、笔画、文字框是**数据**（`note_document.dart`、`ink/*.dart`）；`page_canvas.dart` 只负责采集指针并绘制；`note_page.dart` 负责把两者接起来并持有界面状态。

分层可以参考 Saber，但**不使用**它的 `.sbn2`，也**不要把它的代码抄进仓库**（Saber 是 GPL-3.0，本仓库是 Apache-2.0）。

## 3. 标识、坐标、纸张

`newId()`（`lib/src/ids.dart`）用 `Random.secure()` 生成 UUID v4。笔记、页面、图层、笔画、文字框都用稳定 id，不靠「第几页」或列表下标认领内容。

坐标原点在页面左上角，y 向下，单位是 point（1/72 英寸）。新建页默认 A4 纵向：宽 595.28、高 841.89（`a4Width`、`a4Height`）。新建笔记带一页 A4 和一个空的墨水图层，层名 `defaultInkLayerName = '墨水'`。

一个对象属于它落笔或创建时所在的那一页。画出页面的部分由页面上的 `ClipRect` 裁掉。现在**没有**把笔画几何裁成页内片段再存盘——裁的是绘制，不是数据。

## 4. 磁盘格式

一份笔记是目录包，不是 zip。库根目录里另有一份 `device.json`，只存 `deviceId`；设备 id 属于这台设备，不属于任何笔记。

```text
vault/
  device.json
  标题.yep/
    manifest.json
    assets/                         预留，图片还没做
    pages/{pageId}/
      page.json
      {layerId}.json
      strokes/{strokeId}.json
```

目录名由标题生成：先去掉首尾空白、去掉结尾的 `.yep`、把 `\ / : * ? " < > |` 换成空格、压缩连续空白；结果为空或是 `.`、`..` 时用「未命名」。重名时依次试 `名字 2.yep`、`名字 3.yep`（`_uniqueDirectoryName`）。标题存在 manifest 里，改标题会改 manifest，并在需要时重命名目录。

`manifest.json`：

```json
{
  "id": "笔记 id",
  "title": "标题",
  "formatVersion": 1,
  "pageOrder": ["页 id，按阅读顺序"],
  "deletedPageIds": ["已删除但文件仍留在磁盘上的页 id"]
}
```

`page.json` 只放纸张和图层顺序，不放对象：

```json
{
  "width": 595.28,
  "height": 841.89,
  "layerOrder": ["从底到顶的图层 id"],
  "deletedLayerIds": []
}
```

`{layerId}.json` 是该层的对象队列。笔画不把点写进这个文件，只留引用；文字框因为还会被改，整份 JSON 留在图层里：

```json
{
  "id": "图层 id",
  "name": "墨水",
  "visible": true,
  "locked": false,
  "deletedObjectIds": ["墓碑"],
  "objects": [
    { "type": "strokeRef", "id": "笔画 id" },
    {
      "type": "text",
      "id": "文字框 id",
      "version": 1,
      "x": 0,
      "y": 0,
      "width": 200,
      "height": 80,
      "source": "# Markdown 原文"
    }
  ]
}
```

`strokes/{strokeId}.json` 是完整笔画，`type` 为 `stroke`。打开笔记时 `_expandStrokeRefs` 把 `strokeRef` 换回完整笔画，找不到对应文件就明确报错并停止打开，避免将残缺内容再次保存；图层文件里直接放着完整 `stroke` 的旧数据也读得进来。写回时 `_storedObject` 把笔画收成 `strokeRef`，文字框原样留下。

写入用 `writeAtomic`：先写带唯一后缀的临时文件并 flush，再 rename 覆盖目标。POSIX 使用原子替换；任意 I/O 失败都不先删除原文件。Windows 在无法覆盖现有目标时采用备份与失败回滚，仍需要 Windows 真机验证崩溃窗口。新建笔记先写 `.{目录名}.partial`，写完再改名成正式目录。

已完成笔画的文件只写一次：`_spillStrokes` 看到已有文件中的 `finalized` 为 true 就跳过；未完成的旧草稿允许更新。`changeMarks` 只检查本次新增笔画的文件，不扫描整层全部笔画。`writeJsonAtomic` 在工作 isolate 中编码与写入，`Vault.openNote` 的读取、解码和几何预热也在工作 isolate 中执行。所以重命名之类的操作不会把每条笔画的点重写一遍（`renameNote` 也不会重读页面）。

> 目前没有格式迁移代码。要改字段，先加 `formatVersion` 分支，不要把 v1 的文件读坏。

## 5. `NoteLibrary` 与 `Vault`

`NoteLibrary` 是存储接口，真库是 `Vault`，测试里用内存实现。所有方法都接收并返回 `OpenNote` 快照；**不要假设 `Vault` 会改你手里的旧对象**。页面结构操作接收返回值，编辑显示则先同步修改内存，异步保存的返回值不得替换当前画布。

| 方法 | 行为与边界 |
| --- | --- |
| `listSummaries` | 只读每个 `.yep` 的 `manifest.json`，按标题排序；坏目录（`FormatException`、`FileSystemException`）跳过。列表界面用它。 |
| `listNotes` | 打开整份笔记（含页面与笔画），给测试和需要页面内容的调用方用。 |
| `createNote(title)` | 新 id，一页 A4 + 一个空墨水层，经 `.partial` 目录落地。空标题存为「未命名」。 |
| `openNote(dir)` | 按 `pageOrder` 逐页读，跳过 `deletedPageIds` 里的页，展开笔画引用。 |
| `renameNote(note, title)` | 改 manifest 的标题；目标目录名已存在且与当前不同则抛 `NoteNameTaken`；需要时重命名目录。返回的 `pages` 是内存里那份，不重读磁盘。 |
| `insertPage(pageId, before)` | `emptyCopyOf` 复制纸张尺寸与图层结构（名字、可见、锁定），但换成**新的图层 id**、内容为空；先写页文件再改 `pageOrder`。 |
| `deletePage(pageId)` | 只剩一页时抛 `StateError('至少保留一页')`；否则把 id 放进 `deletedPageIds` 并从 `pageOrder` 移除，**页文件保留**。 |
| `deleteNote(note)` | 递归删掉整个 `.yep` 目录。 |
| `moveLayer` / `setLayerVisible` / `setLayerLocked` | `moveLayer` 越界时原样返回；改可见/锁定只重写该层文件，移动层会重写整页。 |
| `saveTextBox` | 同 id 已存在时 `version = 已有的 version + 1`，新框取 `max(version, 1)`。文字框整份存在图层文件里。 |
| `saveStroke` | 同 id 且已经 `finalized` 的笔画直接原样返回，不覆盖（抬笔后几何不再改）。 |
| `changeMarks` | 一次调用同时处理 `add`（新笔画）、`tombstone`（记删除）、`restore`（去掉删除标记）。 |

`PageFile.layers` 从底到顶。`PageFile.moveLayer` / `updateLayer` 都返回新的 `PageFile`，不改原来的列表。

## 6. 墓碑、撤销栈与写盘时机

删除不把对象从队列里抹掉，而是把 id 记进 `deletedObjectIds`。撤销一次删除时，`changeMarks` 的 `restore` 会把这个 id 从墓碑里拿掉。

`applyMarks` 同步更新内存 `OpenNote`。内存是显示的唯一事实来源，没有 `_hidden` 或 `_settled` 影子状态；保存捕获操作完成时的快照，不能在异步回调里读最新状态后再次套用旧操作。

撤销是线性的：一条 `_MarkEdit` 同时记录新增笔画、旧对象墓碑、文字修改与新文字框。`_commit` 压入撤销栈并清空重做栈；`_retint` 交换新增和墓碑的角色。文字框创建也能撤销。套索取出只是临时显示事务，贴回时才将原对象与最终对象记成一个完整命令；撤销不能停在只有取出、没有贴回的中间状态。

写盘通过 `WriteQueue` 按顺序执行。失败的任务留在队首，后续重试必须先完成它，新的快照不能越过旧任务。页面/图层调整、重命名、删除笔记之前先结束当前编辑并排空写入；正常返回上一页也先排空写入，失败时提示并留在笔记里。换页不清历史，关闭笔记清历史。

`StrokeRecoveryStore` 是可选的增量恢复接口，`Vault` 实现它。书写时按约 32 ms 的采样时间间隔将新增原始采样追加到 `pages/{pageId}/journal/{strokeId}.jsonl`，没有每次重写整条笔画。抬笔后先保存最终笔画，再删恢复日志。打开时将未提交的日志恢复成完成笔画；最后一行被截断时仅保留之前的完整记录。已经存在于对象队列的 id 不再恢复，包括已有墓碑的对象，防止擦除/撤销后复活。它只能恢复已完成实际写盘的采样，不保证程序被强杀时尚在内存或等待 I/O 的样本。

## 7. 笔画

### 7.1 存什么

`StrokeObject`：`id`、`tool`（钢笔写 `"pen"`，荧光笔写 `"highlighter"`）、`color`（`0xAARRGGBB`，钢笔是 `penColor = 0xFF000000`）、`baseWidth`（`penBaseWidth = 3.0`）、`points`、`finalized`。

`StrokePoint`：`x`、`y`、相对起笔的 `time`（秒）、`width`、`height`、`opacity`、`pressure`，可选 `azimuth`、`altitude`。宽和高在采样时就算进点里，抬笔后不再改；渲染直接用这些值，不用新的粗细算法重算旧笔画。

### 7.2 谁能落笔，怎么采样

`drawsInk(kind)`：`stylus`、`invertedStylus`、`mouse` 落笔；`touch`（手指）不落笔，用来平移。文字工具下笔和鼠标也能平移，直到长按被识别成文字手势。

`sampleFromPointer` 从 `PointerEvent` 取采样：只有手写笔事件才读姿态，方位角用 `event.orientation`，高度角用 `π/2 - tilt`，压感按 `pressureMin`/`pressureMax` 归一化后 clamp 到 0..1。鼠标走 `mouseSample`，压感和透明度用固定值，没有姿态。

缺省值：没有压感用 `missingPressure = 0.5`，没有姿态时方位角与高度角为 `null`，透明度 `missingOpacity = 1.0`。

预测点、iOS 的合并触点、Android 的 historical 批次都**还没有**接进采样：Flutter 的 `PointerEvent` 来一个收一个。预测点无论如何都不要写进 `StrokeObject`。

iOS 上 Pencil 的悬停会以鼠标事件进来（系统把 hover 标成 mouse）。悬停只用来画光标，不产生笔画。

### 7.3 因果绘制

实时显示和存盘用的是同一套点。书写过程中 `appendCausalPoint` 逐点追加，抬笔时 `finishStroke` 把尾巴放出来。对一整串原始点再跑一遍就得到最终点列（`bakePenStroke`、`causalPaint`、`densifySamples`）。

已经画出去的点只追加，不回头改。`raw`（原始采样）和 `painted`（已画出的点）**不能是同一个列表**：`appendCausalPoint` 发现两者 `identical` 时会先复制 `painted`。已经因果绘制过的点不要再喂给 `pointsForPaint`，否则会再拟合一次。

lookahead：还没连上的点要等后面的样本才画，`_holdCount` 按相邻采样间隔决定等几个——间隔 ≥ 24 ms 等 4 个，≥ 14 ms 等 3 个，其余等 2 个。抬笔时 `finishStroke(hold: 1)` 把尾巴全放出来。

### 7.4 形状怎么拟合

每一段用三次 Hermite 画，不是整条笔画一次拟合。节点切向由 `_nodeTangent` 从左右邻居取中点差分：`m = Δt · (P[j+1] - P[j-1]) / (t[j+1] - t[j-1])`，首末采样退化成单侧差分。相邻两段问的是同一个节点、拿到同一个 `m`，所以交界处切向一致，采样点上不会再出现尖角。段内曲线本身就经过两端真实采样，不需要再摊误差。

切向只读「前一个 + 后一个」采样，和 `_holdCount` 的 lookahead 是同一份预算，所以已经画过的墨迹不会因为后来的样本被改动。

一条弦怎么处理，由 `_appendArc` 决定：

| 条件 | 结果 |
| --- | --- |
| 弦长 < 1.5（`minFitDistance`） | 直接收下终点，不画曲线 |
| 两端时间相同（`Δt` ≤ 0.0001） | 走直线，点距 `straightSpacing = 1.0` |
| 预估中点弓高超过允许弓高 | 按同一比例缩小两个节点切向，把弓高压回允许值 |
| 其余 | 沿 Hermite 采样；允许弓高 > 2 时用更密的 `tightSpacing = 0.4` |

允许弓高由转角估计（`_allowedBulge` / `_bulgeForTurn`）得到，乘 1.35 且至少为 1。它现在用来夹切向，而不是退回直线：Hermite 的中点弓高正好是 `0.125 · (m_in - m_out)`，`_bulgeScale` 按这个系数等比缩放两个切向；缩放只改变沿线速度、不改变方向，所以和相邻段的交界仍然光滑。转角太平或接近掉头时估计弓高为 0，切向被压到接近 0，段内看起来仍是直线。

`_Poly` / `_PolySums` / `_polyFor` / `_polyFits` / `_fitPoly` 是旧的「局部二次最小二乘 + 端点误差线性摊回」实现，现在不再被调用，留作回滚和对比（声明上带 `// ignore: unused_element`）。`directJoinDistance` 和 `curveWindow` 也随之成了死常量——前者原先那条 `bulge < 0.7` 分支因为 `_allowedBulge` 恒 ≥ 1 而从未生效。

### 7.5 宽和高

`_widthFromPrevious` 在采样时算：`width = baseWidth × (1.1 - 0.2 × pace) × (0.7 + 0.6 × pressure)`，其中 `pace = clamp(speed / 900, 0, 1)`，速度由相邻两点的距离与时间差得到；压感为 0 时按 `missingPressure` 处理。宽和高始终相等。

### 7.6 画出来

`paintStroke` 的实线按相近宽度分组合成圆头、圆角路径；只有一个点时画圆。虚线沿弧长截出每段实线，再以连续的变宽轮廓一次填充，避免独立矩形之间的接缝和毛刺。`paintStrokeCover` 用更宽的圆头描同一条线（`pad` 外扩），给橡皮的遮盖与挖空用。`outlineOf` 把点列包成一条带粗细的闭合 `Path`。

### 7.7 现在只被测试用到的 API

`densifySamples`、`undrawnStrokes` 在生产代码里没有调用方，只被 `test/stroke_test.dart` 使用；`outlineOf` 已用于虚线实线段的连续轮廓填充。常量 `curveWindow = 0.032` 目前没有任何引用。改动它们前先想清楚是删掉还是接进管线，不要留着一半的旧实现。

## 8. 画布与瓦片

`PageCanvas` 纵向排列页面。通过视图变换的逆矩阵计算可见范围；屏幕外页面仅保留等尺寸占位，不建立文本或墨迹渲染器。可见范围预留 128 point 缓冲。

`_PageSheet._orderedContent` 按图层从底到顶、每层对象队列的顺序交错绘制笔画和文字。连续笔画形成一个 `_CommittedInk` 渲染组；文字在自己的原有位置，编辑不会将它挪到队尾。实时笔画放在当前可写层顶部，上方锁定图层仍能覆盖它。

`_CommittedInk` 使用 256 point 瓦片，只对页面内当前可见范围生成图像；离屏图像超过每个渲染组 64 MiB 的预算时回收，当前可见图像不强制丢弃。不可变的完成笔画按需缓存成 `ui.Picture`，离开可见范围及其缓冲区的矢量缓存也会回收。修改对象、透明度或图层顺序时只标记涉及瓦片的受影响矩形。旧瓦片的其他像素继续显示，受影响区域同步显示当前矢量对象；后台复制旧瓦片、清除该矩形、按当前对象顺序重建该矩形，最后一次性换图并撤去矢量过渡。所有重建有代数校验，过期异步结果只能释放，不能回写。缩放结束更新 `viewScale` 后重新生成对应分辨率的瓦片。

这与长期保留橡皮遮罩不同：缓存只描述当前对象的显示结果，后续新笔画不会再被旧遮罩挖掉。交叉笔画也能从真实对象重建。`InkPatch` 仅保留兼容接口，不再作为破坏对象外观的事实来源。

`_LiveInk` 缓存当前笔画的稳定前缀，末端约 8 个点保持矢量尾巴。`_imagedDistance` 记录已缓存前缀的弧长，每个新块与尾巴传给 `paintStroke` 的 `distanceOffset` 延续整笔虚线相位。区域擦除另在片段中保存 `dashOffset`，与实时分块偏移相加；旧笔画缺少该字段时按 0 读取。复制保留相位，缩放时相位与循环长度一起缩放。完成后通过内存对象和受影响区域的矢量过渡接到瓦片，显示交接不等待磁盘。

## 9. 橡皮

工具栏只显示一个橡皮。笔画与区域两种模式共用 `_eraserRadius`，默认 14，调整范围 4–48，显示半径与几何命中使用同一个值。

对象橡皮通过 `_InkLocator` 查询附近笔画。空间索引覆盖笔画点以及相邻点之间的实际线段，不能只索引端点。桶坐标使用 `(x, y)` 二元组，避免负坐标或大坐标的整数编码碰撞。接触对象后直接将其原有绘制结果整体降至 40% 透明度，边缘一起降低，并保留对象堆叠顺序；抬笔后记录墓碑。

区域橡皮在落笔和移动时立即对候选对象运行 `eraseRegion`。`_regionPieces` 按原对象记录当前剩余片段，并在原队列位置插入新片段；抬笔只提交一次撤销命令，包含原笔画 id 与最终片段。删除中间片段不会让它们留在持久化队列中。

当前可画图层仍是该页最上面一层可见且未锁定的图层。对象命中、编辑和渲染必须共同遵守页面 id、图层可见状态与墓碑。

## 10. 手势与平移

`NotePage` 用 `TickerProviderStateMixin`，在 `PageCanvas` 外面套了一层 `Listener`（`behavior: translucent`），三个回调都在 `NotePage` 上：`_fingerDown` / `_fingerMove` / `_fingerUp`。

- 只有触摸、或者文字工具下的笔和鼠标参与平移（`_fingerDown` 里的 `pans`）。
- 单指平移。速度用相邻位移做指数混合（旧值 0.45、即时值 0.55）。抬笔时速度小于 80 不甩；Ticker 里每帧乘 `exp(-3.4 × dt)`，速度小于 12 停止。
- 第二根手指按下会把 `_multiTouch` 置上并清掉速度，两指平移**不甩**；`_multiTouch` 在最后一根手指抬起时清掉。
- 手指正在平移时如果笔落下，`_endMoving` 结束平移并把当前还没抬起的触摸指针放进 `_ignoredFingers`，这些手指要抬起之后才能再平移。
- 文字工具下，长按计时开始时 `onSuppressPan` 把该指针从平移里拿掉；按下后移动超过 10 point（`_textSlop`）且长按还没成立，就取消文字计时，这次手势继续当平移。
- `InteractiveViewer` 自己的双指缩放惯性保持 Flutter 默认，不要把 `interactionEndFrictionCoefficient` 改成 1。
- 进入笔记后只居中一次：视口中心对齐页面中心，四周留 48（`_scheduleCenter`，在首帧后执行）。

缩放按钮（`_zoom(1.2)` / `_zoom(1 / 1.2)`）和捏合结束走同一个 `_settleScale`。

## 11. 文字框

模型是 `TextBox`：`id`、`version`、`x`、`y`、`width`、`height`、`source`。`source` 是 Markdown 原文。文字框属于创建时所在的那一层，和笔画一样是图层里的对象。

**创建**：文字工具下按下约 380 ms（`_textHold`）后开始拖，预览先半透明，宽 ≥ 72（`_textMinWidth`）且高 ≥ 44（`_textMinHeight`）后变不透明；只有抬笔时尺寸够了才 `onTextCreate`。点一下空白不是创建，而是 `onTextBlur`（结束编辑、取消选中、收起焦点）。

**编辑**：短按已有文字框进入编辑，看到的是 `TextField` 里的源码；失焦后改用 `MarkdownBody` 渲染。渲染字号不随框缩放：正文 `textBodySize = 14`，h1 22、h2 18、h3 16，列表缩进用渲染器自己的 `ListConfig(marginLeft: 24)`。空源码显示灰色「文字」。编辑时有边框和半透明白底，退出编辑后没有。

**公式**：`markdown_math.dart` 按 `markdown_widget` 示例的写法，把 `$...$` 与 `$$...$$` 交给 `flutter_math_fork` 的 `Math.tex` 绘制，解析失败时回退成红色原文。不要去写只认 `\frac` 的解析器。

**选中、移动、改大小**：长按已有文字框，或在文字工具下悬停该框时按侧键，都会选中它。选中后可以拖动框体移动（位置 clamp 在页内），拖右下角外的方块改大小（`_TextFrame` 内先 clamp 到 64..2000 / 40..2000，`_resizeText` 再 clamp 到页面边界），框旁边出现「编辑」和「删除」菜单。删除走墓碑，因此在撤销栈上。离开文字工具会清掉正在编辑和选中的 id。

**草稿与顺序陷阱**：`onChanged` 把草稿放进 `_textDrafts`，**不为此 `setState`**。失焦提交必须先读 `TextEditingController.text`，再把 `widget.box.source` 写回 controller——顺序反了会把刚打的字用旧的空源码盖掉。`_persistText` 只有在这份保存的源码、宽、高仍然对得上当前草稿时才丢掉草稿，避免一次较晚的空保存把字抹掉。`_TextFrame` 用 `_committed` 标记防止焦点回调和 `didUpdateWidget` 各提交一次。

进入笔记时 `_editingTextId` 从 `null` 开始，并在首帧后 `unfocus`，所以不会有文字框自动进入编辑。

中文输入法的组字过程仍会进入文字框（日程第 8 阶段），文字编辑本身也没有独立的撤销栈；文字框的**删除**已经在墨迹撤销栈上。

## 12. 侧面按键与工具弧

侧面按键不是 Apple Pencil 专有功能。各平台只报告「侧面按键按下了」，**应用才决定做什么**。

Dart 接口是 `StylusSideButton`（`lib/src/input/stylus_side_button.dart`）：

- `addListener` / `removeListener`：界面注册。同时有多个监听者时只调用**最后注册**的那个——笔记页在库页面之上，所以打开笔记时由笔记页接收。
- `report(Offset? globalPosition)`：平台或测试调用，坐标是全局坐标，平台不知道就传 `null`。

原生走方法通道 `dev.yetanotherpage/stylus`，方法名 `sideButton`，参数是可含数字 `x`、`y` 的 Map；没有坐标就传空 Map 或不传。`main` 里 `stylusSideButton.attachPlatform()` 接上这个通道。

iOS 的适配在 `ios/Runner/AppDelegate.swift`：`ApplePencilSideButton` 在 `didInitializeImplicitFlutterEngine` 里注册通道，并在应用回到前台时重新挂到窗口上；`PencilSqueezeRelay` 用 iOS 17.5+ 的 `UIPencilInteraction`，只在捏笔阶段 `.ended` 时上报，有 `hoverPose` 就带上坐标。**不要在这里决定打开工具栏还是选中文字框。**

收到按键后：

- 笔记页：文字工具且正悬停在某个文字框上 → 选中该框；否则开/关圆弧工具栏。
- 库页面：正悬停在某条笔记上 → 打开重命名/删除菜单。

圆弧工具栏（`tool_arc.dart`）：半径 108 的上半弧，按钮 48，项为钢笔、文字、对象橡皮、区域橡皮、撤销、重做（key 分别是 `arc-pen`、`arc-text`、`arc-object-eraser`、`arc-region-eraser`、`arc-undo`、`arc-redo`）。轨道透明，只有图标圆和一条细线。撤销/重做不关闭圆弧，切换工具会关闭。

## 13. 悬停光标

非触摸的 hover 显示笔尖：钢笔按当前选中的颜色和基础笔宽显示圆点；荧光笔按当前颜色、固定笔宽和 `highlighterOpacity = 0.35` 显示半透明圆形，页面缩放同时作用于笔迹和预览。橡皮是白底黑边的圆圈，半径用 `eraserRadius`。文字工具不显示点也不显示圆，但仍把位置交给 `onTip` 和 `onTextHover`，供侧键选中文字框。按下绘画时笔尖位置继续更新。不要对悬停坐标做几何预测。

## 14. 图层与库界面

图层面板把 `page.layers` 倒过来画，让最上面的层出现在列表上方；每行可以隐藏、锁定、上移、下移，最上面和最下面的层对应的方向按钮置灰。顺序存在 `layerOrder` 里。隐藏的层不画；锁定的层不能当当前绘制层。目前只能隐藏、锁定、排序——批量加层和合并图层还没做（`deletedLayerIds` 字段已经在格式里占好位）。

库页面列出 `listSummaries` 的结果（副标题显示目录名），长按或「悬停 + 侧键」弹出「重命名」「删除」，右下角「新建笔记」。打开笔记先推一个 `_NoteGate`，显示「正在打开笔记」，等 `openNote` 完成后才构建 `NotePage`；新建笔记也走这道门，返回后重新列一遍。

> 写界面测试时，进度圈还在转的时候**不要** `pumpAndSettle`，会超时。`test/widget_test.dart` 在过场期间用显式的 `pump(Duration)`，等过场结束才 `pumpAndSettle`。

## 15. 测试

```bash
flutter test
```

- `test/vault_test.dart`：用真实临时目录（`Directory.systemTemp.createTemp`），是普通 `test()`，**不要**放进 `FakeAsync` 里等真实磁盘。覆盖设备 id、建/开/改名/删除、插页删页、图层可见性与顺序、抬笔后形状不变、墓碑与恢复、文字框版本号。
- `test/stroke_test.dart`：锁住采样、lookahead、拟合与宽度，包括鼠标固定值、因果点不回改、圆上的弦不塌成直线。
- `test/eraser_test.dart`：锁住命中与裁切——整条命中、整条擦空、部分擦掉留两段且宽高不变、新 id 与旧 id 不同。
- `test/text_box_test.dart`：界面测试，确认标题、列表、强调和 `$...$` 公式真的画出来（`find.byType(Math)`），且源码里的 `\frac`、`$` 不再出现在可读文本里。
- `test/widget_test.dart`：用内存库 `_MemoryLibrary` 走一遍新建/打开笔记，并用 `stylusSideButton.report` 确认侧键能开、能关、能选工具。

约定：

- `TextEditingController`、`FocusNode`、`ValueNotifier`、`Ticker` 必须在 State 里 `dispose`。
- `_MemoryLibrary implements NoteLibrary`，用不到的接口方法抛 `UnimplementedError`；`NoteLibrary` 新增方法时这里必须补上，否则测试编译不过。
- 库测试不依赖应用支持目录，也不依赖真实设备。

## 16. 改代码时不要破坏的事

- 抬笔后的笔画几何不再修改。新外观写成新 id，旧 id 墓碑。
- 预测点、合并触点的重复点，都不要写进 `StrokeObject`。
- `raw` 与 `painted` 不要共享同一个列表；实时笔画的 `shouldRepaint` 不要去比较一份还在被改的列表。
- 橡皮的补丁（`InkPatch`）和 fade（`StrokeFade`）都带 `pageId`，不要画到别的页上。
- 区域橡皮只重画碰到的瓦片，不要退化成整页重建。
- 抬笔后必须同步交接到已提交对象的矢量过渡，不能产生等待瓦片的空帧。
- 单指才有惯性；两指平移不要甩。
- 文字失焦时先读 controller，再重置 controller；`_textDrafts` 的丢弃条件不能放宽。
- 最后一页不能删；删页和删对象都是墓碑，文件留在磁盘上。
- 写盘时机在编辑发生时，不要挪到退出时；所有写盘继续走 `WriteQueue`。
- 笔画文件只写一次，`strokes/{id}.json` 不要被反复覆盖。
- 平台代码只调用 `sideButton` / `report`，不要在原生代码里决定界面行为。
- 不要把 PencilKit 用于存储或渲染。

## 17. 已知限制

这些是当前实现的边界，不是「下次顺手改掉」的行为：

- 图片、PDF 导入、导出副本、`.yep` 导入导出、嵌套文件夹、局域网同步都还没做；`assets/` 只是预留目录。
- 文字编辑失焦后记入笔记统一撤销栈；不是逐个字符的独立历史。
- 长笔画上的圆仍可能有直线棱，那只剩密化折线本身（点距 0.4 / 1.0）：节点切向已经连续，输入抖动带来的可见拐角要靠上游的因果低通解决。不要在绘制时把已经存下的点整体重算。
- 双指移动没有我们自己的惯性；捏合的收尾动画是 `InteractiveViewer` 的。
- iOS 合并触点、Android historical 采样还没接进笔画。
- 页外的笔画是画的时候裁掉，不是存盘时裁成页内几何。
- 侧键目前只有 iOS 有原生实现；Android 的 `MainActivity` 还是空模板。
- macOS 的发布 entitlements 只有 `app-sandbox`（调试额外有 `allow-jit` 和 `network.server`），以后做局域网同步要补 `network.client`。

## 18. 给另一个平台接侧面按键

1. 在原生代码里收到笔的侧面按键，并且确认手势已经结束。
2. 平台能给指针位置就换成 Flutter 视图里的全局坐标；给不出就不传坐标，**不要编一个**。
3. 调用方法通道 `dev.yetanotherpage/stylus` 的 `sideButton`，参数 `{"x": ..., "y": ...}`。
4. 不要在原生代码里打开菜单或切换工具。笔记页和库页面已经在监听 `stylusSideButton`。

iOS 的对照实现是 `ApplePencilSideButton` 和 `PencilSqueezeRelay`（`ios/Runner/AppDelegate.swift`）。

## 19. 参考原则与修正记录

本次只参考 Saber 对笔画几何缓存、实时笔画与页面内容分开管理、历史项记录完整操作的设计思路，不复制第三方实现。参考：[Stroke](https://github.com/saber-notes/saber/blob/main/lib/components/canvas/_stroke.dart)、[EditorHistory](https://github.com/saber-notes/saber/blob/main/lib/data/editor/editor_history.dart)。本项目继续使用自己的笔画格式、拟合算法、瓦片缓存与 `.yep` 存储。

逐项问题、修复位置与验证范围见 [底层修正记录](refactor-notes.md)。

## 20. 荧光笔与密集笔画

荧光笔复用钢笔的采样和稳定曲线管线，但保持固定笔宽。默认预设为 12、18、24，默认颜色为黄色，整体透明度为 0.35。`highlighter.json` 保存独立预设，不覆盖钢笔的 `pen.json`；两种工具都通过预设长条和二级圆弧调整。

`paintStroke` 对单条荧光笔的几何先以不透明颜色画入临时层，再统一应用透明度。实时前缀和尾巴也先作为一个整体合成，所以单笔自交、分块交接不会叠出深色接缝。不同笔画分别合成，重叠会加深。不能改成每个采样段分别使用半透明 paint。

`FrozenStrokePoints` 复制原始输入后冻结，复制笔画元数据时直接共享它。区域擦除剩余片段使用只读切片，并复用根采样块的边界；命中只检查附近块。`StrokeJsonPoints` 是只读惰性 JSON 点列表，生成内存快照不逐点分配字典，实际遍历交给存储线程。`LayerFile.strokeCache` 只存在内存里，不写入格式字段；加载时普通逐点 JSON 对象被转换成冻结几何与惰性列表，避免长期保留两套点数据。

`StrokeSpatialIndex` 按 32 个采样点的块建立 128 point 网格，只对新 id 建立空间索引，并释放不再活动的对象。局部查询返回当前对象顺序下的候选笔画，橡皮、套索和瓦片更新再做精确判断。`_editableStrokes` 缓存图层几何，渲染不能在每个对象循环中重复构建墓碑集合。

套索在连续拖动、旋转和缩放时只更新累计矩阵；手势结束也不遍历所有点。复制或最终贴回时才生成相应几何。文字 Markdown 的 source 和宽度不变时复用渲染 widget。

性能回归见 `test/spatial_index_test.dart`（一万笔画、32 万采样点）、`test/eraser_test.dart`（十万点笔画局部擦除）和 `test/widget_test.dart`（三千笔画密集页面的书写、橡皮、套索变换和缩放）。这些测试覆盖正确性与局部查询范围，运行耗时是本机测试环境观测，不能等同于 iPad/Android 的真实帧率。像素一致性见 `test/brush_render_test.dart`。

钢笔默认虚实预设为纯实线和虚实各占半，循环长度均为 24 point。读取旧版未调整的单一纯实线默认预设时会补上半虚半实；写回后通过 `dashPresetVersion` 标记，后续用户主动减少槽位不会再自动补回。荧光笔与自定义虚实预设保持原样。
