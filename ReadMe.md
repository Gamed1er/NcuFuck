# NcuFuck

用 **x86 組合語言（MASM, 32-bit）** 寫的編譯器，把 **NCU 語言**的程式編譯成可以直接執行的 Windows `.exe`。

```
> NcuFuck examples\hello.ncu
examples\hello.ncu: 106 tokens -> 59 operations
OK: hello.exe

> hello.exe
Hello World!
```

中央大學資工系「組合語言」期末專題。

---

## NCU 語言

NCU 語言是 [Brainfuck](https://en.wikipedia.org/wiki/Brainfuck) 的變體：8 個指令全部改用 `n` `c` `u` 三個字母的大小寫組合來寫。

| NCU | Brainfuck | 意義 |
|---|---|---|
| `Ncu` | `<` | 指標左移一格 |
| `ncU` | `>` | 指標右移一格 |
| `ncu` | `-` | 目前格子 −1 |
| `NCU` | `+` | 目前格子 +1 |
| `nCu` | `.` | 輸出目前格子（ASCII） |
| `NcU` | `,` | 讀一個字元到目前格子（EOF 時為 0） |
| `nCU` | `[` | 目前格子是 0 就跳到對應的 `NCu` 之後 |
| `NCu` | `]` | 目前格子不是 0 就跳回對應的 `nCU` |

- 指令之間用空白、Tab 或換行隔開，**大小寫有差**
- `//` 到行尾是註解
- 記憶帶有 30000 格，每格 1 byte（0～255，超過會繞回），一開始都是 0

範例（`examples\cat.ncu`，把輸入原樣印出來）：
```
// cat: read a char and print it, until EOF
NcU nCU nCu NcU NCu
```

---

## 需要的環境

- Windows
- Visual Studio 2022 Community（提供 `ml.exe`、`link.exe`）+ Windows SDK
- [Irvine32 函式庫](https://github.com/surferkip/asmbook)，解壓縮到 `C:\Irvine`

路徑不同的話，請修改 `make.bat` 和 `ncu_build.bat` 裡的 `vcvars32.bat` 路徑和 `C:\Irvine`。

## 建置編譯器

```
make
```
會產生 `NcuFuck.exe`。`NcuFuck.exe` 執行時會呼叫 `ncu_build.bat`，兩個檔案要放在**同一個資料夾**。

## 使用方式

```
NcuFuck [選項] <檔案.ncu>
```

| 選項 | 作用 |
|---|---|
| （不加） | 編譯成 `<檔名>.exe`，放在目前資料夾 |
| `-o <檔案>` | 指定輸出檔，例如 `-o bin\hello.exe`（`.exe` 可省略；資料夾要先存在） |
| `-S` | 只產生組合語言 `.asm`，不組譯 |
| `--save-temps` | 保留中間檔（`.asm` / `.obj` / `.log`） |
| `--tokens` | 只印出斷詞結果（每個指令的行號和對應的 Brainfuck 符號） |
| `--no-opt` | 關掉最佳化，可以用來比較最佳化前後 |

選項和檔名的順序隨意，例如 `NcuFuck -o bin\a.exe hello.ncu` 也可以。

需要輸入的程式可以用 pipe 餵資料：
```
echo hello| cat.exe
```
（PowerShell 的 pipe 會在前面多送 3 個 byte 的 BOM，測輸入建議用 cmd。）

## 範例程式

| 檔案 | 內容 |
|---|---|
| `examples\hello.ncu` | 印出 `Hello World!` |
| `examples\loop.ncu` | 用巢狀迴圈印出星星三角形 |
| `examples\cat.ncu` | 把輸入原樣印出來 |
| `examples\error_*.ncu` | 故意寫錯的程式，用來展示錯誤訊息 |

---

## 運作原理

```
hello.ncu
   │  NcuFuck.exe（本專題，組合語言寫的）
   │   1. 讀檔
   │   2. 斷詞：比對 8 種指令，記下行號
   │   3. 括號配對：檢查迴圈有沒有成對，幫每個迴圈編號
   │   4. 產生組合語言（含最佳化）
   ▼
hello.asm
   │  用 CreateProcess 執行 ncu_build.bat（ml + link）
   ▼
hello.exe
```

### 產生的程式碼

記憶帶指標放在 `ESI`，每個指令翻譯成一小段 x86 組語：

| NCU | 產生的組語 |
|---|---|
| `NCU` × n | `add BYTE PTR [esi], n` |
| `ncu` × n | `sub BYTE PTR [esi], n` |
| `ncU` × n | `add esi, n` |
| `Ncu` × n | `sub esi, n` |
| `nCu` | `mov al, [esi]` / `call ncu_putc` |
| `NcU` | `call ncu_getc` / `mov [esi], al` |
| `nCU` | `L_open_k:` / `cmp BYTE PTR [esi], 0` / `je L_close_k` |
| `NCu` | `cmp BYTE PTR [esi], 0` / `jne L_open_k` / `L_close_k:` |

### 最佳化：Run-length 合併

連續相同的指令會合併成一行：`NCU NCU NCU` → `add BYTE PTR [esi], 3`。
`hello.ncu` 的 106 個指令最後只產生 59 段程式碼；用 `-S` 和 `-S --no-opt` 各產生一次 `.asm` 就能比較差別。

### 錯誤訊息

會標出錯誤的行號、欄位和原始碼位置：
```
Error (line 4, col 13): unknown token 'NCUU'
    NCU ncU NcU NCUU nCu
                ^^^^
Hint: valid tokens are Ncu ncU ncu NCU nCu NcU nCU NCu
```
```
Error (line 3, col 1): 'nCU' has no matching 'NCu'
    nCU ncu
    ^^^
```

### 用到的組合語言技巧

| 主題 | 在哪裡 |
|---|---|
| `STRUCT` | 每個指令存成 `TOKEN`（opcode、行號、迴圈編號、位置）；`CreateProcess` 需要的 `STARTUP_INFO`、`PROC_INFO` |
| Stack / Stack Frame | 括號配對直接用 CPU 的 stack：遇到 `[` 就 `push`、遇到 `]` 就 `pop`；計數器用 `LOCAL` 宣告 |
| 字串指令 | `repe cmpsb` 比對指令、`lodsb` / `stosb` 串接路徑 |
| 查表 | `codeTable[op*4]` 用 opcode 直接查出要產生的程式碼 |
| `INVOKE` / `PROTO` | 自己宣告 Irvine 沒有的 Win32 函式 |
| Win32 API | `CreateProcessA`、`WaitForSingleObject`、`GetExitCodeProcess`、`GetModuleFileNameA`、`DeleteFileA`、`WriteFile` / `ReadFile` |

---

## 檔案結構

```
NcuFuck.asm      編譯器本體
make.bat         建置 NcuFuck.exe
ncu_build.bat    NcuFuck 呼叫的組譯腳本（ml + link）
examples\        範例程式
```
