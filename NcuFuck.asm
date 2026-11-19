; =====================================================================
; NcuFuck.asm — NCU 語言編譯器（組合語言期末專題）
;
; 用法：NcuFuck [選項] <檔案.ncu>        （選項跟 g++ 一樣，順序隨意）
;   （不加選項）    編譯成 <檔名>.exe，放在目前資料夾
;   -o <路徑>       指定輸出檔（-o bin\hello.exe）
;   -S              只產生組語 .asm，不組譯
;   --save-temps    保留中間檔（.asm / .obj / .log）
;   --tokens        只印出斷詞結果（token 清單 + 行號）
;   --no-opt        關掉 run-length 合併（拿來比較最佳化前後）
;
; 流程：讀檔 → 斷詞 → 括號配對 → 產生 .asm → 呼叫 ncu_build.bat（ml + link）
; =====================================================================

INCLUDE Irvine32.inc

main EQU start@0

; =====================================================================
; Irvine 的 SmallWin.inc 沒有宣告的 Win32 函式和結構，自己補上
; =====================================================================
DeleteFileA PROTO,                  ; 刪除檔案（清掉中間檔用）
    lpFileName:PTR BYTE

GetModuleFileNameA PROTO,           ; 取得「自己這個 exe」的完整路徑
    hModule:DWORD,                  ; 0 = 自己
    lpFilename:PTR BYTE,            ; 結果放這裡
    nSize:DWORD                     ; buffer 大小

; CreateProcess 要的啟動設定（全部填 0 就是「跟我一樣」，只有 cb 要填結構大小）
STARTUP_INFO STRUCT
    cb              DWORD ?         ; 這個結構的大小（SIZEOF STARTUP_INFO = 68）
    lpReserved      DWORD ?
    lpDesktop       DWORD ?
    lpTitle         DWORD ?
    dwX             DWORD ?
    dwY             DWORD ?
    dwXSize         DWORD ?
    dwYSize         DWORD ?
    dwXCountChars   DWORD ?
    dwYCountChars   DWORD ?
    dwFillAttribute DWORD ?
    dwFlags         DWORD ?
    wShowWindow     WORD  ?
    cbReserved2     WORD  ?
    lpReserved2     DWORD ?
    hStdInput       DWORD ?
    hStdOutput      DWORD ?
    hStdError       DWORD ?
STARTUP_INFO ENDS

; CreateProcess 回傳的新程序資訊
PROC_INFO STRUCT
    hProcess    DWORD ?             ; 新程序的 handle（用來等它、拿 exit code）
    hThread     DWORD ?             ; 新程序主執行緒的 handle
    dwProcessId DWORD ?
    dwThreadId  DWORD ?
PROC_INFO ENDS

; CreateProcessA：執行另一個程式
;   lpApplicationName    0 = 從命令列的第一個字找程式
;   lpCommandLine        完整命令列
;   lpProcess/ThreadAttributes  0 = 預設
;   bInheritHandles      1 = 子程序可以用我的 handle（輸出才會到同一個地方）
;   dwCreationFlags      0 = 預設
;   lpEnvironment        0 = 用我的環境變數
;   lpCurrentDirectory   0 = 用我的目前資料夾
; （MASM 會把續行接成同一行，續行裡寫註解會超過長度上限，所以註解寫在上面）
CreateProcessA PROTO, lpApplicationName:PTR BYTE, lpCommandLine:PTR BYTE,
    lpProcessAttributes:DWORD, lpThreadAttributes:DWORD, bInheritHandles:DWORD,
    dwCreationFlags:DWORD, lpEnvironment:DWORD, lpCurrentDirectory:PTR BYTE,
    lpStartupInfo:PTR STARTUP_INFO, lpProcessInformation:PTR PROC_INFO

WaitForSingleObject PROTO,          ; 等某個 handle（這裡是子程序）結束
    hHandle:DWORD,
    dwMilliseconds:DWORD            ; 最多等幾毫秒，INFINITE = 一直等

GetExitCodeProcess PROTO,           ; 拿子程序的 exit code
    hProcess:DWORD,
    lpExitCode:PTR DWORD

INFINITE = 0FFFFFFFFh

; ---------- 常數 ----------
MAX_FILE   = 100000         ; 原始檔最大 bytes
MAX_TOKENS = 100000         ; 最多幾個 token
MAX_OUT    = 12000000       ; 產生的 .asm 最大 bytes（每個 token 最多約 70 bytes + 行號註解，夠用）
ARG_SIZE   = 260            ; 命令列 / 路徑 buffer 大小
NUM_OPS    = 8              ; NCU 語言共 8 種指令
OP_OPEN    = 6              ; [ 的 opcode
OP_CLOSE   = 7              ; ] 的 opcode
MAX_SHOW   = 30             ; 錯誤訊息中最多顯示 token 的幾個字元
CR_LF      EQU <0Dh, 0Ah>   ; 文字巨集：換行，寫在 BYTE 字串後面用

; ---------- 一個 token 的資料結構 ----------
TOKEN STRUCT
    op     BYTE  ?          ; opcode 0~7（對應 tokenTable 的順序）
    line   DWORD ?          ; 這個 token 在原始檔的第幾行
    loopId DWORD ?          ; 只有 [ ] 用：第幾個迴圈（一對 [ ] 編號相同）
    pos    DWORD ?          ; token 在 fileBuf 裡的位址（錯誤訊息標位置用）
TOKEN ENDS

; ---------- 自己寫的 PROC 宣告 ----------
ParseArgs    PROTO
LoadSource   PROTO
Tokenize     PROTO
LookupToken  PROTO
PrintTokens  PROTO
SkipSpaces   PROTO
CopyWord     PROTO
Fatal        PROTO
PutStr       PROTO
PutChar      PROTO
PutDec       PROTO
PutCrlf      PROTO
NumToStr     PROTO
MakeOutPath  PROTO
ArgIs        PROTO
AppendStr    PROTO
GenerateAsm  PROTO
WriteAsmFile PROTO
EmitStr      PROTO
EmitDec      PROTO
EmitCrlf     PROTO
MatchBrackets PROTO
PutOpName    PROTO
RunBuild     PROTO
LineStart    PROTO
ErrorHead    PROTO
ShowSourceLine PROTO
PrintHint    PROTO

.data
; =====================================================================
; ★ 指令對應表 ★ —— 要改語法只要改這裡
; 第 i 個 3 字元字串 = opcode i，bfChars 的第 i 個字元是它對應的 BF 符號
; =====================================================================
tokenTable  BYTE "Ncu"      ; 0  <  指標左移
            BYTE "ncU"      ; 1  >  指標右移
            BYTE "ncu"      ; 2  -  格子 -1
            BYTE "NCU"      ; 3  +  格子 +1
            BYTE "nCu"      ; 4  .  輸出
            BYTE "NcU"      ; 5  ,  輸入
            BYTE "nCU"      ; 6  [  迴圈開始
            BYTE "NCu"      ; 7  ]  迴圈結束
bfChars     BYTE "<>-+.,[]"

; ---------- 命令列選項 ----------
optTokens   BYTE "--tokens", 0
showTokens  BYTE 0          ; 1 = 有下 --tokens
optNoOpt    BYTE "--no-opt", 0
optimize    BYTE 1          ; 1 = 做 run-length 合併（預設），--no-opt 會改成 0
optOut      BYTE "-o", 0
optAsmOnly  BYTE "-S", 0
asmOnly     BYTE 0          ; 1 = 有下 -S：只產生 .asm，不組譯
optTemps    BYTE "--save-temps", 0
saveTemps   BYTE 0          ; 1 = 有下 --save-temps：保留 .asm / .obj / .log

; ---------- 訊息字串 ----------
msgUsage    BYTE "NcuFuck - NCU language compiler", 0Dh, 0Ah
            BYTE "Usage: NcuFuck [options] <file.ncu>", 0Dh, 0Ah
            BYTE "  -o <file>      write output to <file> (default: <name>.exe)", 0Dh, 0Ah
            BYTE "  -S             generate assembly (.asm) only", 0Dh, 0Ah
            BYTE "  --save-temps   keep .asm / .obj / .log", 0Dh, 0Ah
            BYTE "  --tokens       print the token list only", 0Dh, 0Ah
            BYTE "  --no-opt       turn off run-length optimization", 0Dh, 0Ah, 0
msgOpenErr  BYTE "Error: cannot open file: ", 0
msgReadErr  BYTE "Error: cannot read file", 0
msgTooBig   BYTE "Error: source file too large", 0
msgTooMany  BYTE "Error: too many tokens", 0
msgBadOpt   BYTE "Error: unknown option: ", 0
msgErrLine  BYTE "Error (line ", 0
msgUnknown  BYTE "): unknown token '", 0
msgQuote    BYTE "'", 0
msgDots     BYTE "...", 0
msgTokHead  BYTE "Tokens of ", 0
msgColon    BYTE ":", 0
msgLine     BYTE "  line ", 0
msgArrow    BYTE "   ->  ", 0
msgTotal    BYTE "Total: ", 0
msgTokens   BYTE " tokens", 0
msgWriteErr BYTE "Error: cannot create output file: ", 0
msgNoOut    BYTE "Error: missing file name after -o", 0
msgTwoIn    BYTE "Error: only one input file is allowed", 0
msgStat1    BYTE ": ", 0
msgStat2    BYTE " tokens -> ", 0
msgStat3    BYTE " operations", 0
msgCol      BYTE ", col ", 0
msgIndent   BYTE "    ", 0
msgHint     BYTE "Hint: valid tokens are ", 0
msgMatch1   BYTE "): '", 0
msgMatch2   BYTE "' has no matching '", 0
msgLoopNo   BYTE "   loop #", 0

; ---------- 輸出檔名 ----------
strAsmExt   BYTE ".asm", 0          ; 副檔名都是 4 個字元，MakeOutPath 會用到
strExeExt   BYTE ".exe", 0
strCrlf     BYTE CR_LF, 0

; ---------- 呼叫 ncu_build.bat ----------
; 完整命令列：cmd.exe /c ""C:\...\ncu_build.bat" "bin\hello" keep"
; （cmd /c 會拿掉最外層的一對引號，所以裡面的路徑有空白也沒問題）
batName     BYTE "ncu_build.bat", 0
cmdPrefix   BYTE 'cmd.exe /c ""', 0
strQSQ      BYTE '" "', 0
strQ        BYTE '"', 0
strKeep     BYTE " keep", 0         ; --save-temps：叫 ncu_build.bat 不要刪 .obj / .log
msgOK       BYTE "OK: ", 0
msgProcErr  BYTE "Error: cannot run ", 0
msgBuildErr BYTE "Error: build failed", 0

; =====================================================================
; 產生出來的 .asm 的固定部分（樣板）
; =====================================================================
asmComment  BYTE "; Generated by NcuFuck from ", 0

asmHeader   BYTE "INCLUDE Irvine32.inc", CR_LF
            BYTE "main EQU start@0", CR_LF
            BYTE CR_LF
            BYTE ".data?", CR_LF
            BYTE "tape    BYTE 30000 DUP(?)   ; the tape (Windows fills .data? with 0)", CR_LF
            BYTE "stdIn   DWORD ?", CR_LF
            BYTE "stdOut  DWORD ?", CR_LF
            BYTE "ioCount DWORD ?", CR_LF
            BYTE "ioChar  BYTE ?", CR_LF
            BYTE CR_LF
            BYTE ".code", CR_LF
            BYTE "; ---- runtime: print the char in AL ----", CR_LF
            BYTE "ncu_putc PROC USES eax ecx edx", CR_LF
            BYTE "    mov  ioChar, al", CR_LF
            BYTE "    INVOKE WriteFile, stdOut, ADDR ioChar, 1, ADDR ioCount, 0", CR_LF
            BYTE "    ret", CR_LF
            BYTE "ncu_putc ENDP", CR_LF
            BYTE CR_LF
            BYTE "; ---- runtime: read one char into AL (EOF -> 0, CR is skipped) ----", CR_LF
            BYTE "ncu_getc PROC USES ecx edx", CR_LF
            BYTE "again:", CR_LF
            BYTE "    mov  ioCount, 0", CR_LF
            BYTE "    INVOKE ReadFile, stdIn, ADDR ioChar, 1, ADDR ioCount, 0", CR_LF
            BYTE "    mov  al, 0", CR_LF
            BYTE "    cmp  ioCount, 0", CR_LF
            BYTE "    je   done", CR_LF
            BYTE "    mov  al, ioChar", CR_LF
            BYTE "    cmp  al, 0Dh", CR_LF
            BYTE "    je   again", CR_LF
            BYTE "done:", CR_LF
            BYTE "    ret", CR_LF
            BYTE "ncu_getc ENDP", CR_LF
            BYTE CR_LF
            BYTE "main PROC", CR_LF
            BYTE "    INVOKE GetStdHandle, STD_INPUT_HANDLE", CR_LF
            BYTE "    mov  stdIn, eax", CR_LF
            BYTE "    INVOKE GetStdHandle, STD_OUTPUT_HANDLE", CR_LF
            BYTE "    mov  stdOut, eax", CR_LF
            BYTE "    mov  esi, OFFSET tape       ; ESI = tape pointer", CR_LF, 0

asmFooter   BYTE CR_LF
            BYTE "    exit", CR_LF
            BYTE "main ENDP", CR_LF
            BYTE "END main", CR_LF, 0

asmLineCmt  BYTE "    ; ---- line ", 0

; 每個 opcode 產生的程式碼
; opcode 0~3 後面還要接一個數字（之後 M5 的 run-length 合併會用到）
code0       BYTE "    sub  esi, ", 0                  ; Ncu  <
code1       BYTE "    add  esi, ", 0                  ; ncU  >
code2       BYTE "    sub  BYTE PTR [esi], ", 0       ; ncu  -
code3       BYTE "    add  BYTE PTR [esi], ", 0       ; NCU  +
code4       BYTE "    mov  al, [esi]", CR_LF          ; nCu  .
            BYTE "    call ncu_putc", CR_LF, 0
code5       BYTE "    call ncu_getc", CR_LF           ; NcU  ,
            BYTE "    mov  [esi], al", CR_LF, 0
; 迴圈（k 是迴圈編號，由程式接在中間）
;   [  →  L_open_k: / cmp BYTE PTR [esi], 0 / je L_close_k
;   ]  →  cmp BYTE PTR [esi], 0 / jne L_open_k / L_close_k:
asmOpen1    BYTE "L_open_", 0
asmOpen2    BYTE ":", CR_LF
            BYTE "    cmp  BYTE PTR [esi], 0", CR_LF
            BYTE "    je   L_close_", 0
asmClose1   BYTE "    cmp  BYTE PTR [esi], 0", CR_LF
            BYTE "    jne  L_open_", 0
asmClose2   BYTE CR_LF
            BYTE "L_close_", 0
asmClose3   BYTE ":", CR_LF, 0

; 查表用：codeTable[op*4] = 該 opcode 樣板字串的位址
codeTable   DWORD OFFSET code0, OFFSET code1, OFFSET code2
            DWORD OFFSET code3, OFFSET code4, OFFSET code5

.data?                      ; .data? = 未初始化資料，不會佔 exe 檔案大小
cmdTail     BYTE ARG_SIZE DUP(?)    ; 命令列（去掉程式名稱後）
srcPath     BYTE ARG_SIZE DUP(?)    ; 第 1 個參數：原始檔路徑
argBuf      BYTE ARG_SIZE DUP(?)    ; 目前正在看的選項
outArg      BYTE ARG_SIZE DUP(?)    ; -o 後面的路徑（沒給 = 空字串）
fileHandle  DWORD ?
fileLen     DWORD ?                 ; 實際讀到幾個 bytes
fileBuf     BYTE MAX_FILE DUP(?)    ; 原始檔內容
tokenCount  DWORD ?
tokens      TOKEN MAX_TOKENS DUP(<>)
stdOut      DWORD ?                 ; 標準輸出的 handle
numWritten  DWORD ?                 ; WriteFile 回報寫了幾個 bytes
charBuf     BYTE ?                  ; PutChar 用的 1 byte buffer
decBuf      BYTE 12 DUP(?)          ; NumToStr 用：32 位元數字最多 10 位 + 結尾 0
baseName    BYTE ARG_SIZE DUP(?)    ; 原始檔的主檔名（hello.ncu → hello）
outPath     BYTE ARG_SIZE+16 DUP(?) ; 產生的組語檔路徑（bin\hello.asm）
outHandle   DWORD ?
outBase     BYTE ARG_SIZE+8 DUP(?)  ; 不含副檔名的輸出路徑（bin\hello）
exePath     BYTE ARG_SIZE+16 DUP(?) ; out\hello.exe
batPath     BYTE ARG_SIZE+16 DUP(?) ; ncu_build.bat 的完整路徑
cmdLine     BYTE 1024 DUP(?)        ; 給 CreateProcess 的命令列
startInfo   STARTUP_INFO <>         ; .data? 會被清成 0
procInfo    PROC_INFO <>
exitCode    DWORD ?                 ; ncu_build.bat 的 exit code
lastLine    DWORD ?                 ; GenerateAsm 用：上一個 token 的行號
opCount     DWORD ?                 ; GenerateAsm 用：合併後剩幾段程式碼（統計用）
outPtr      DWORD ?                 ; outBuf 目前寫到哪裡
outBuf      BYTE MAX_OUT DUP(?)     ; 產生的 .asm 內容

.code
; =====================================================================
main PROC
; 主流程：解析參數 → 讀檔 → 斷詞 →（--tokens 時）印出 token
; =====================================================================
    INVOKE GetStdHandle, STD_OUTPUT_HANDLE  ; Win32：拿到標準輸出的 handle
    mov  stdOut, eax

    INVOKE ParseArgs
    jnc  args_ok               ; CF=0 代表有給檔名
    mov  edx, OFFSET msgUsage
    call PutStr
    INVOKE ExitProcess, 1       ; 結束程式並回傳 exit code 1

args_ok:
    INVOKE LoadSource
    INVOKE Tokenize
    INVOKE MatchBrackets        ; 檢查 [ ] 是否成對，並幫迴圈編號

    cmp  showTokens, 1
    jne  generate
    INVOKE PrintTokens          ; --tokens：只印 token 就結束
    jmp  done
generate:
    INVOKE MakeOutPath          ; 決定輸出檔名 out\xxx.asm
    INVOKE GenerateAsm          ; 產生組語到 outBuf
    INVOKE WriteAsmFile         ; outBuf 寫進 .asm 檔
    cmp  asmOnly, 1             ; -S：只要 .asm，到這裡就結束
    jne  build
    mov  edx, OFFSET msgOK      ; "OK: hello.asm"
    call PutStr
    mov  edx, OFFSET outPath
    call PutStr
    call PutCrlf
    jmp  done
build:
    INVOKE RunBuild             ; 呼叫 ncu_build.bat 產生 .exe
done:
    exit                        ; exit code 0
main ENDP

; =====================================================================
ParseArgs PROC USES eax edx esi edi
; 解析命令列參數
; 輸入：無（自己去拿命令列）
; 輸出：srcPath    = 原始檔路徑
;       outArg     = -o 後面的輸出路徑（沒給就是空字串）
;       showTokens = 1 如果有 --tokens
;       optimize   = 0 如果有 --no-opt
;       asmOnly    = 1 如果有 -S
;       saveTemps  = 1 如果有 --save-temps
;       CF = 1 代表沒給原始檔（呼叫者要印用法）
; 修改：只有旗標（其他都有 USES 保護）
; 規則：- 開頭的是選項，其他的是原始檔；順序隨意（跟 g++ 一樣）
; =====================================================================
    mov  edx, OFFSET cmdTail
    call GetCommandTail         ; Irvine：把程式名稱後面的字串複製到 EDX
    mov  esi, OFFSET cmdTail
    mov  srcPath, 0             ; 先設成空字串，用來判斷有沒有給原始檔
    mov  outArg, 0

next_word:
    INVOKE SkipSpaces
    cmp  BYTE PTR [esi], 0      ; 全部讀完了
    je   end_args
    cmp  BYTE PTR [esi], '-'    ; - 開頭 → 選項
    je   is_option

    ; ---- 不是選項 → 原始檔 ----
    cmp  srcPath, 0             ; 已經有一個原始檔了
    jne  two_inputs
    mov  edi, OFFSET srcPath
    INVOKE CopyWord
    jmp  next_word

is_option:
    mov  edi, OFFSET argBuf
    INVOKE CopyWord

    mov  edx, OFFSET optOut     ; -o <檔名>
    call ArgIs
    jne  try_S
    INVOKE SkipSpaces
    cmp  BYTE PTR [esi], 0      ; -o 後面沒東西
    je   missing_out
    mov  edi, OFFSET outArg
    INVOKE CopyWord
    jmp  next_word
try_S:
    mov  edx, OFFSET optAsmOnly ; -S
    call ArgIs
    jne  try_temps
    mov  asmOnly, 1
    jmp  next_word
try_temps:
    mov  edx, OFFSET optTemps   ; --save-temps
    call ArgIs
    jne  try_tokens
    mov  saveTemps, 1
    jmp  next_word
try_tokens:
    mov  edx, OFFSET optTokens  ; --tokens
    call ArgIs
    jne  try_noopt
    mov  showTokens, 1
    jmp  next_word
try_noopt:
    mov  edx, OFFSET optNoOpt   ; --no-opt
    call ArgIs
    jne  bad_opt
    mov  optimize, 0
    jmp  next_word

end_args:
    cmp  srcPath, 0             ; 沒給原始檔
    je   no_args
    clc                         ; CF = 0：成功
    ret
no_args:
    stc                         ; CF = 1：沒參數
    ret

bad_opt:
    mov  edx, OFFSET msgBadOpt
    call PutStr
    mov  edx, OFFSET argBuf
    INVOKE Fatal                ; 印出選項並結束，不會回來
missing_out:
    mov  edx, OFFSET msgNoOut
    INVOKE Fatal
two_inputs:
    mov  edx, OFFSET msgTwoIn
    INVOKE Fatal
ParseArgs ENDP

; =====================================================================
ArgIs PROC USES eax ecx edx esi edi
; 比較 argBuf 和某個選項字串是否相同
; 輸入：EDX = 選項字串（例如 "-o"）
; 輸出：ZF = 1 代表相同（呼叫後接 je / jne）
; 修改：只有旗標（USES 的 pop 不會改旗標）
; =====================================================================
    INVOKE Str_compare, ADDR argBuf, edx   ; Irvine：比較兩字串，結果放旗標
    ret
ArgIs ENDP

; =====================================================================
SkipSpaces PROC
; 跳過空白與 Tab
; 輸入：ESI = 字串目前位置
; 輸出：ESI = 第一個不是空白的字元
; 修改：ESI
; =====================================================================
L1: cmp  BYTE PTR [esi], ' '
    je   skip
    cmp  BYTE PTR [esi], 9      ; 9 = Tab
    je   skip
    ret
skip:
    inc  esi
    jmp  L1
SkipSpaces ENDP

; =====================================================================
CopyWord PROC USES eax ebx
; 複製一個「字」（到空白、Tab 或字串結尾為止），結尾補 0
; 雙引號裡面的空白不算分隔，引號本身不複製
;   例："my dir\a b.ncu" → my dir\a b.ncu
; 輸入：ESI = 來源，EDI = 目的地
; 輸出：ESI 停在字的後面，EDI 指向補上的 0
; 修改：ESI、EDI
; =====================================================================
    mov  bl, 0                  ; BL = 1 代表目前在引號裡面
L1: mov  al, [esi]
    cmp  al, 0
    je   done
    cmp  al, '"'
    jne  not_quote
    xor  bl, 1                  ; XOR 1：0 變 1、1 變 0（進出引號）
    inc  esi
    jmp  L1
not_quote:
    cmp  bl, 1                  ; 在引號裡：空白也照抄
    je   copy_it
    cmp  al, ' '
    je   done
    cmp  al, 9
    je   done
copy_it:
    mov  [edi], al
    inc  esi
    inc  edi
    jmp  L1
done:
    mov  BYTE PTR [edi], 0
    ret
CopyWord ENDP

; =====================================================================
LoadSource PROC USES eax ecx edx
; 把 srcPath 整個檔案讀進 fileBuf
; 輸入：srcPath
; 輸出：fileBuf = 檔案內容，fileLen = 長度
; 修改：無（失敗時直接結束程式）
; =====================================================================
    mov  edx, OFFSET srcPath
    call OpenInputFile          ; Irvine：EAX = file handle
    cmp  eax, INVALID_HANDLE_VALUE
    je   open_err
    mov  fileHandle, eax

    mov  edx, OFFSET fileBuf
    mov  ecx, MAX_FILE
    call ReadFromFile           ; Irvine：EAX = 讀到幾個 bytes，失敗時 CF = 1
    jc   read_err
    mov  fileLen, eax

    mov  eax, fileHandle
    call CloseFile

    cmp  fileLen, MAX_FILE      ; 剛好塞滿 buffer → 檔案可能更大，當作太大
    jae  too_big
    ret

open_err:
    mov  edx, OFFSET msgOpenErr
    call PutStr
    mov  edx, OFFSET srcPath
    INVOKE Fatal
read_err:
    mov  edx, OFFSET msgReadErr
    INVOKE Fatal
too_big:
    mov  edx, OFFSET msgTooBig
    INVOKE Fatal
LoadSource ENDP

; =====================================================================
Tokenize PROC USES eax ebx ecx edx esi edi
; 斷詞：把 fileBuf 切成 token，存進 tokens 陣列
;   - 空白 / Tab / CR / LF 是分隔符號，遇到 LF 行號 +1
;   - "//" 到行尾是註解
;   - 其他字元連在一起就是一個 token，必須是對應表裡的 3 字元指令
; 輸入：fileBuf、fileLen
; 輸出：tokens[]、tokenCount（遇到不認識的 token 會印錯誤並結束）
; 修改：無
; 暫存器用途：ESI = 目前讀到的位置   EBX = 檔案結尾
;             EDX = 目前行號        EDI = 下一個要寫入的 TOKEN
; =====================================================================
    mov  esi, OFFSET fileBuf
    mov  ebx, esi
    add  ebx, fileLen           ; EBX = 檔案結尾（最後一個 byte 的下一個）
    mov  edx, 1                 ; 行號從 1 開始
    mov  edi, OFFSET tokens
    mov  tokenCount, 0

next_char:
    cmp  esi, ebx
    jae  finished
    mov  al, [esi]

    cmp  al, 0Ah                ; LF = 換行
    jne  not_lf
    inc  edx
    inc  esi
    jmp  next_char
not_lf:
    cmp  al, ' '
    je   skip_char
    cmp  al, 9                  ; Tab
    je   skip_char
    cmp  al, 0Dh                ; CR（Windows 換行是 CR LF）
    je   skip_char

    ; 是不是 "//" 註解？
    cmp  al, '/'
    jne  read_token
    lea  ecx, [esi+1]           ; LEA：只算位址不讀記憶體，ECX = ESI + 1
    cmp  ecx, ebx               ; 後面還有字元嗎？
    jae  read_token
    cmp  BYTE PTR [esi+1], '/'
    jne  read_token
skip_comment:                   ; 一直跳到 LF（LF 本身留給上面處理行號）
    inc  esi
    cmp  esi, ebx
    jae  finished
    cmp  BYTE PTR [esi], 0Ah
    jne  skip_comment
    jmp  next_char

skip_char:
    inc  esi
    jmp  next_char

read_token:
    ; 找出 token 的結尾：遇到空白、Tab、CR、LF、"//" 或檔案結尾就停
    mov  ecx, esi               ; ECX = token 起點
find_end:
    inc  esi
    cmp  esi, ebx
    jae  got_token
    mov  al, [esi]
    cmp  al, ' '
    je   got_token
    cmp  al, 9
    je   got_token
    cmp  al, 0Dh
    je   got_token
    cmp  al, 0Ah
    je   got_token
    cmp  al, '/'
    jne  find_end
    lea  eax, [esi+1]
    cmp  eax, ebx
    jae  find_end
    cmp  BYTE PTR [esi+1], '/'
    jne  find_end

got_token:
    ; 現在 ECX = 起點，ESI = 結尾；查表
    push esi                    ; 先存起來，LookupToken 要用 ESI 當起點
    push ecx
    xchg esi, ecx               ; XCHG：交換兩個暫存器 → ESI = 起點，ECX = 結尾
    sub  ecx, esi               ; ECX = 長度
    INVOKE LookupToken          ; EAX = opcode 或 -1
    pop  ecx                    ; ECX = 起點
    pop  esi                    ; ESI = 結尾
    cmp  eax, -1
    je   unknown_token

    cmp  tokenCount, MAX_TOKENS
    jae  too_many
    mov  (TOKEN PTR [edi]).op, al      ; 存 opcode
    mov  (TOKEN PTR [edi]).line, edx   ; 存行號
    mov  (TOKEN PTR [edi]).pos, ecx    ; 存在原始檔中的位置（錯誤訊息要用）
    add  edi, SIZEOF TOKEN             ; 移到下一格
    inc  tokenCount
    jmp  next_char

finished:
    ret

unknown_token:
    ; 印出：
    ;   Error (line 4, col 13): unknown token 'NCUU'
    ;       NCU ncU NcU NCUU nCu
    ;                   ^^^^
    ;   Hint: valid tokens are Ncu ncU ncu NCU nCu NcU nCU NCu
    mov  ebx, esi
    sub  ebx, ecx               ; EBX = token 長度
    mov  eax, edx               ; EAX = 行號
    mov  edx, ecx               ; EDX = token 起點
    call ErrorHead              ; "Error (line N, col C"
    push edx
    mov  edx, OFFSET msgUnknown ; "): unknown token '"
    call PutStr
    pop  edx

    ; 印出 token 本身（最多 MAX_SHOW 個字元，太長就加 ...）
    mov  esi, edx
    mov  ecx, ebx
    cmp  ecx, MAX_SHOW
    jbe  print_tok
    mov  ecx, MAX_SHOW
print_tok:
    mov  al, [esi]
    call PutChar
    inc  esi
    loop print_tok
    push edx
    cmp  ebx, MAX_SHOW
    jbe  close_quote
    mov  edx, OFFSET msgDots
    call PutStr
close_quote:
    mov  edx, OFFSET msgQuote
    call PutStr
    call PutCrlf
    pop  edx

    mov  ecx, ebx               ; ECX = token 長度
    call ShowSourceLine         ; 印出那一行原始碼 + ^^^ 標出位置
    call PrintHint              ; 列出合法的 token
    INVOKE ExitProcess, 1

too_many:
    mov  edx, OFFSET msgTooMany
    INVOKE Fatal
Tokenize ENDP

; =====================================================================
LookupToken PROC USES ebx ecx esi edi
; 在 tokenTable 裡找這個 token 是哪一個指令
; 輸入：ESI = token 起點，ECX = token 長度
; 輸出：EAX = opcode（0 ~ NUM_OPS-1），找不到 = -1
; 修改：EAX
; =====================================================================
    mov  eax, -1
    cmp  ecx, 3                 ; 每個指令都剛好 3 個字元
    jne  done

    mov  ebx, 0                 ; EBX = 目前比對的 opcode
    mov  edi, OFFSET tokenTable
    cld                         ; 方向旗標清 0：字串指令往前走
compare_next:
    push esi
    push edi
    mov  ecx, 3
    repe cmpsb                  ; 比較 [ESI] 和 [EDI]，相同就繼續，最多 3 次
    pop  edi
    pop  esi
    je   found                  ; 3 個字元都一樣 → ZF = 1
    add  edi, 3                 ; 換表裡的下一個指令
    inc  ebx
    cmp  ebx, NUM_OPS
    jb   compare_next
    jmp  done                   ; 全部比完都不一樣，EAX 維持 -1
found:
    mov  eax, ebx
done:
    ret
LookupToken ENDP

; =====================================================================
PrintTokens PROC USES eax ebx ecx edx esi
; 印出所有 token：行號、NCU 寫法、對應的 BF 符號
; 輸入：tokens[]、tokenCount
; 輸出：螢幕
; 修改：無
; =====================================================================
    mov  edx, OFFSET msgTokHead
    call PutStr
    mov  edx, OFFSET srcPath
    call PutStr
    mov  edx, OFFSET msgColon
    call PutStr
    call PutCrlf

    mov  ecx, tokenCount
    jecxz print_total           ; JECXZ：ECX = 0 就跳（沒有 token 時 loop 會跑 2^32 次）
    mov  esi, OFFSET tokens
print_one:
    ; "  line N"
    mov  edx, OFFSET msgLine
    call PutStr
    mov  eax, (TOKEN PTR [esi]).line
    call PutDec
    mov  al, 9                  ; Tab 對齊
    call PutChar

    ; NCU 寫法
    movzx ebx, (TOKEN PTR [esi]).op   ; MOVZX：BYTE 放進 32 位元暫存器，高位補 0
    mov  al, bl
    call PutOpName

    ; "   ->  " + BF 符號
    mov  edx, OFFSET msgArrow
    call PutStr
    mov  al, bfChars[ebx]
    call PutChar

    ; 迴圈指令再印出迴圈編號 "  loop #k"
    cmp  ebx, OP_OPEN
    jb   end_line
    mov  edx, OFFSET msgLoopNo
    call PutStr
    mov  eax, (TOKEN PTR [esi]).loopId
    call PutDec
end_line:
    call PutCrlf

    add  esi, SIZEOF TOKEN
    dec  ecx                    ; 迴圈本體超過 128 bytes，LOOP 跳不到
    jnz  print_one

print_total:
    mov  edx, OFFSET msgTotal
    call PutStr
    mov  eax, tokenCount
    call PutDec
    mov  edx, OFFSET msgTokens
    call PutStr
    call PutCrlf
    ret
PrintTokens ENDP

; =====================================================================
Fatal PROC
; 印出錯誤訊息、換行，然後用 exit code 1 結束程式（不會 return）
; 輸入：EDX = 訊息字串
; =====================================================================
    call PutStr
    call PutCrlf
    INVOKE ExitProcess, 1
Fatal ENDP

; =====================================================================
; 輸出函式
; 為什麼不用 Irvine 的 WriteString / WriteChar？
;   Irvine 底層用 WriteConsole，輸出被導向（例如 NcuFuck ... > out.txt
;   或被別的程式用 pipe 讀取）時會什麼都印不出來。
;   這裡改用 WriteFile 寫到標準輸出 handle，螢幕和檔案都能用。
; 四個函式都不會改任何暫存器（和 Irvine 版本一樣好用）
; =====================================================================

PutStr PROC USES eax ecx edx
; 印出以 0 結尾的字串
; 輸入：EDX = 字串位址
    INVOKE Str_length, edx      ; Irvine：EAX = 字串長度
    INVOKE WriteFile, stdOut, edx, eax, ADDR numWritten, 0
    ret
PutStr ENDP

PutChar PROC USES eax ecx edx
; 印出一個字元
; 輸入：AL = 字元
    mov  charBuf, al
    INVOKE WriteFile, stdOut, ADDR charBuf, 1, ADDR numWritten, 0
    ret
PutChar ENDP

PutDec PROC USES edx
; 印出無號十進位整數
; 輸入：EAX = 數字
    call NumToStr               ; EDX = 數字字串
    call PutStr
    ret
PutDec ENDP

PutCrlf PROC USES eax
; 換行（CR LF）
    mov  al, 0Dh
    call PutChar
    mov  al, 0Ah
    call PutChar
    ret
PutCrlf ENDP

; =====================================================================
NumToStr PROC USES eax ebx edi
; 把無號整數轉成十進位字串
; 輸入：EAX = 數字
; 輸出：EDX = 字串位址（放在 decBuf 裡，下次呼叫會被蓋掉）
; 修改：EDX
; 作法：一直除以 10，餘數就是最後一位，從 buffer 尾巴往前填
; =====================================================================
    mov  edi, OFFSET decBuf + 11
    mov  BYTE PTR [edi], 0      ; 字串結尾
    mov  ebx, 10
next_digit:
    xor  edx, edx               ; DIV 會用 EDX:EAX 當被除數，先把 EDX 清 0
    div  ebx                    ; EAX = 商，EDX = 餘數 (0~9)
    add  dl, '0'                ; 數字 → ASCII
    dec  edi
    mov  [edi], dl
    test eax, eax               ; 商還不是 0 就繼續
    jnz  next_digit
    mov  edx, edi
    ret
NumToStr ENDP

; =====================================================================
MakeOutPath PROC USES eax ebx ecx edx esi edi
; 算出輸出檔的路徑
;   沒有 -o：examples\hello.ncu → outBase = "hello"（放在目前資料夾）
;   有 -o  ：-o bin\hi.exe      → outBase = "bin\hi"（.exe / .asm 會切掉）
;   然後 outPath = outBase + ".asm"，exePath = outBase + ".exe"
; 輸入：srcPath、outArg
; 輸出：baseName、outBase、outPath、exePath
; 修改：無
; =====================================================================
    ; 1. 找最後一個 '\' 或 '/' 的後面 → 檔名起點放 EBX
    mov  esi, OFFSET srcPath
    mov  ebx, esi
scan:
    mov  al, [esi]
    cmp  al, 0
    je   scanned
    inc  esi
    cmp  al, '\'
    je   mark
    cmp  al, '/'
    jne  scan
mark:
    mov  ebx, esi               ; 斜線的下一個字元
    jmp  scan
scanned:

    ; 2. 檔名複製到 baseName，同時記住最後一個 '.' 的位置（EDX）
    mov  esi, ebx
    mov  edi, OFFSET baseName
    mov  edx, 0                 ; 0 = 還沒看到 '.'
copy:
    mov  al, [esi]
    mov  [edi], al
    cmp  al, 0
    je   copied
    cmp  al, '.'
    jne  copy_next
    mov  edx, edi
copy_next:
    inc  esi
    inc  edi
    jmp  copy
copied:
    ; 3. 把副檔名切掉（在 '.' 的位置填 0）
    cmp  edx, 0
    je   build_path
    cmp  edx, OFFSET baseName   ; 檔名是 ".ncu" 這種開頭就是點的，不切
    je   build_path
    mov  BYTE PTR [edx], 0

build_path:
    ; 4. 決定 outBase
    mov  edi, OFFSET outBase
    cmp  outArg, 0              ; 有沒有 -o？
    jne  use_out_arg
    mov  edx, OFFSET baseName   ; 沒有：就用原始檔的主檔名
    call AppendStr
    jmp  make_names

use_out_arg:
    mov  edx, OFFSET outArg     ; 有：用 -o 給的路徑
    call AppendStr              ; EDI = 結尾的 0
    ; 最後 4 個字元是 ".exe" 或 ".asm" 就切掉
    lea  ebx, [edi-4]           ; EBX = 最後 4 個字元的開頭
    cmp  ebx, OFFSET outBase    ; 路徑不到 4 個字元
    jb   make_names
    cld
    mov  esi, ebx
    mov  edi, OFFSET strExeExt
    mov  ecx, 4
    repe cmpsb                  ; 跟 ".exe" 比
    je   cut_ext
    mov  esi, ebx
    mov  edi, OFFSET strAsmExt
    mov  ecx, 4
    repe cmpsb                  ; 跟 ".asm" 比
    jne  make_names
cut_ext:
    mov  BYTE PTR [ebx], 0

make_names:
    ; 5. outPath = outBase + ".asm"
    mov  edi, OFFSET outPath
    mov  edx, OFFSET outBase
    call AppendStr
    mov  edx, OFFSET strAsmExt
    call AppendStr
    ; 6. exePath = outBase + ".exe"
    mov  edi, OFFSET exePath
    mov  edx, OFFSET outBase
    call AppendStr
    mov  edx, OFFSET strExeExt
    call AppendStr
    ret
MakeOutPath ENDP

; =====================================================================
AppendStr PROC USES eax esi
; 把字串接在 EDI 後面（連結尾的 0 一起複製）
; 輸入：EDX = 要接上去的字串，EDI = 目的地目前的結尾
; 輸出：EDI 指向新的結尾 0（可以直接再接下一段）
; 修改：EDI
; =====================================================================
    mov  esi, edx
    cld
L1: lodsb                       ; LODSB：AL = [ESI]，ESI + 1
    stosb                       ; STOSB：[EDI] = AL，EDI + 1
    cmp  al, 0
    jne  L1
    dec  edi                    ; 退回到 0 上面
    ret
AppendStr ENDP

; =====================================================================
GenerateAsm PROC USES eax ebx ecx edx esi
; 把 tokens[] 翻譯成組語文字，存進 outBuf
; 輸入：tokens[]、tokenCount、srcPath
; 輸出：outBuf、outPtr（指向內容結尾）
; 修改：無（必須先跑過 MatchBrackets，迴圈編號才會有值）
; 暫存器用途：ESI = 目前的 TOKEN   ECX = 剩幾個 token   EBX = opcode
; =====================================================================
    mov  outPtr, OFFSET outBuf
    mov  lastLine, 0
    mov  opCount, 0

    ; 檔頭："; Generated by NcuFuck from xxx.ncu" + 樣板
    mov  edx, OFFSET asmComment
    call EmitStr
    mov  edx, OFFSET srcPath
    call EmitStr
    call EmitCrlf
    mov  edx, OFFSET asmHeader
    call EmitStr

    mov  esi, OFFSET tokens
    mov  ecx, tokenCount
    test ecx, ecx               ; 沒有 token 就直接寫結尾
    jz   footer                 ; （不能用 JECXZ：它跟 LOOP 一樣只能跳 ±128 bytes，footer 太遠）

gen_one:
    ; 換到新的一行原始碼時，插入一行註解，方便對照
    mov  eax, (TOKEN PTR [esi]).line
    cmp  eax, lastLine
    je   same_line
    mov  lastLine, eax
    mov  edx, OFFSET asmLineCmt
    call EmitStr
    call EmitDec
    call EmitCrlf
same_line:
    inc  opCount                ; 統計：產生了幾段程式碼

    movzx ebx, (TOKEN PTR [esi]).op
    cmp  ebx, OP_OPEN
    je   gen_open
    cmp  ebx, OP_CLOSE
    je   gen_close
    cmp  ebx, 3                 ; opcode 4、5（輸出入）不合併、不接數字
    ja   emit_code

    ; ---- run-length 合併：數一數後面還有幾個一樣的指令 ----
    ; 例：NCU NCU NCU → add BYTE PTR [esi], 3（3 行變 1 行）
    mov  eax, 1                 ; EAX = 連續幾個
    cmp  optimize, 0            ; --no-opt：不合併
    je   merged
count_same:
    cmp  ecx, 1                 ; 已經是最後一個 token
    je   merged
    cmp  (TOKEN PTR [esi + SIZEOF TOKEN]).op, bl   ; 下一個 token 一樣嗎？
    jne  merged
    add  esi, SIZEOF TOKEN      ; 一樣 → 吃掉它
    dec  ecx
    inc  eax
    jmp  count_same
merged:
    cmp  ebx, 2                 ; opcode 2、3 是改格子的值，只有 0~255
    jb   emit_count             ; opcode 0、1 是移動指標，不用處理
    and  eax, 0FFh              ; 除以 256 取餘數（256 個 + 等於沒變）
    jz   next_token             ; 剛好 256 的倍數：什麼都不用做

emit_count:
    mov  edx, codeTable[ebx*4]  ; 查表：一個位址 4 bytes，所以 op*4
    call EmitStr
    call EmitDec                ; 接上數字 n
    call EmitCrlf
    jmp  next_token

emit_code:
    mov  edx, codeTable[ebx*4]
    call EmitStr
    jmp  next_token

gen_open:
    ; 第 k 個迴圈的開頭：
    ;   L_open_k:
    ;       cmp  BYTE PTR [esi], 0
    ;       je   L_close_k
    mov  eax, (TOKEN PTR [esi]).loopId  ; EAX = k
    mov  edx, OFFSET asmOpen1
    call EmitStr
    call EmitDec
    mov  edx, OFFSET asmOpen2
    call EmitStr
    call EmitDec
    call EmitCrlf
    jmp  next_token

gen_close:
    ; 第 k 個迴圈的結尾：
    ;       cmp  BYTE PTR [esi], 0
    ;       jne  L_open_k
    ;   L_close_k:
    mov  eax, (TOKEN PTR [esi]).loopId
    mov  edx, OFFSET asmClose1
    call EmitStr
    call EmitDec
    mov  edx, OFFSET asmClose2
    call EmitStr
    call EmitDec
    mov  edx, OFFSET asmClose3
    call EmitStr

next_token:
    add  esi, SIZEOF TOKEN
    dec  ecx                    ; 迴圈本體太長，LOOP 跳不到（LOOP 只能跳 ±128 bytes）
    jnz  gen_one

footer:
    mov  edx, OFFSET asmFooter
    call EmitStr
    ret
GenerateAsm ENDP

; =====================================================================
MatchBrackets PROC USES eax ebx ecx esi
    LOCAL depth:DWORD, nextId:DWORD
; 括號配對：檢查每個 [ 都有對應的 ]，並幫每一對編上同一個迴圈編號
; 輸入：tokens[]、tokenCount
; 輸出：每個 [ 和 ] 的 TOKEN.loopId（不成對時印錯誤並結束）
; 修改：無
; 作法：直接用 CPU 的 stack —— 遇到 [ 就把它的位址 push，
;       遇到 ] 就 pop 出「最近一個還沒配對的 [」，兩個就是一對
; LOCAL：區域變數放在這個 PROC 的 stack frame 裡（[ebp-4]、[ebp-8]），
;        所以中間 push / pop 改變 ESP 也不影響讀寫它們
; =====================================================================
    mov  depth, 0               ; 目前 stack 裡有幾個還沒配對的 [
    mov  nextId, 0              ; 下一個迴圈編號
    mov  esi, OFFSET tokens
    mov  ecx, tokenCount
    jecxz check_end

scan:
    mov  al, (TOKEN PTR [esi]).op
    cmp  al, OP_OPEN
    jne  not_open
    ; ---- 遇到 [：給它新編號，位址 push 進 stack ----
    mov  eax, nextId
    mov  (TOKEN PTR [esi]).loopId, eax
    inc  nextId
    push esi
    inc  depth
    jmp  next

not_open:
    cmp  al, OP_CLOSE
    jne  next
    ; ---- 遇到 ]：pop 出對應的 [，抄它的編號 ----
    cmp  depth, 0               ; stack 是空的 → 這個 ] 多出來了
    je   extra_close
    pop  ebx                    ; EBX = 對應的 [ 的 TOKEN 位址
    dec  depth
    mov  eax, (TOKEN PTR [ebx]).loopId
    mov  (TOKEN PTR [esi]).loopId, eax

next:
    add  esi, SIZEOF TOKEN
    dec  ecx
    jnz  scan

check_end:
    cmp  depth, 0               ; 全部看完，stack 還有 [ → 少了 ]
    jne  missing_close
    ret

extra_close:
    ; Error (line N): 'NCu' has no matching 'nCU'
    mov  eax, (TOKEN PTR [esi]).line
    mov  bl, OP_CLOSE
    mov  bh, OP_OPEN
    jmp  report
missing_close:
    ; Error (line N): 'nCU' has no matching 'NCu'（N = 最內層沒配對的 [ 的行號）
    pop  esi
    mov  eax, (TOKEN PTR [esi]).line
    mov  bl, OP_OPEN
    mov  bh, OP_CLOSE
report:
    ; EAX = 行號，ESI = 出問題的 TOKEN，BL = 出問題的指令，BH = 缺少的指令
    mov  edx, (TOKEN PTR [esi]).pos
    call ErrorHead              ; "Error (line N, col C"
    push edx
    mov  edx, OFFSET msgMatch1
    call PutStr
    mov  al, bl
    call PutOpName
    mov  edx, OFFSET msgMatch2
    call PutStr
    mov  al, bh
    call PutOpName
    mov  edx, OFFSET msgQuote
    call PutStr
    call PutCrlf
    pop  edx
    mov  ecx, 3                 ; 指令都是 3 個字元
    call ShowSourceLine
    INVOKE ExitProcess, 1
MatchBrackets ENDP

; =====================================================================
LineStart PROC
; 找出某個位置所在那一行的開頭
; 輸入：EDX = fileBuf 裡的位置
; 輸出：EBX = 那一行第一個字元的位置
; 修改：EBX
; =====================================================================
    mov  ebx, edx
L1: cmp  ebx, OFFSET fileBuf    ; 已經到檔案開頭
    je   done
    cmp  BYTE PTR [ebx-1], 0Ah  ; 前一個字元是換行 → 這裡就是行首
    je   done
    dec  ebx
    jmp  L1
done:
    ret
LineStart ENDP

; =====================================================================
ErrorHead PROC USES eax ebx edx
; 印出錯誤訊息的開頭 "Error (line N, col C"
; 輸入：EAX = 行號，EDX = 出錯的位置（fileBuf 裡）
; 修改：無
; =====================================================================
    push edx
    mov  edx, OFFSET msgErrLine ; "Error (line "
    call PutStr
    call PutDec
    mov  edx, OFFSET msgCol     ; ", col "
    call PutStr
    pop  edx
    call LineStart              ; EBX = 行首
    mov  eax, edx
    sub  eax, ebx
    inc  eax                    ; 第幾個字元 = 位置 - 行首 + 1
    call PutDec
    ret
ErrorHead ENDP

; =====================================================================
ShowSourceLine PROC USES eax ebx ecx edx esi edi
; 印出出錯的那一行原始碼，下一行用 ^^^ 標出錯的地方
; 輸入：EDX = 出錯的位置（fileBuf 裡），ECX = 要標幾個字元
; 修改：無
; =====================================================================
    call LineStart              ; EBX = 行首
    mov  edi, OFFSET fileBuf
    add  edi, fileLen           ; EDI = 檔案結尾

    ; ---- 第 1 行：縮排 + 原始碼（印到換行或檔案結尾）----
    push edx
    mov  edx, OFFSET msgIndent
    call PutStr
    pop  edx
    mov  esi, ebx
print_src:
    cmp  esi, edi
    jae  src_done
    mov  al, [esi]
    cmp  al, 0Dh
    je   src_done
    cmp  al, 0Ah
    je   src_done
    call PutChar
    inc  esi
    jmp  print_src
src_done:
    call PutCrlf

    ; ---- 第 2 行：縮排 + 空白一直到出錯的位置 + ^^^ ----
    push edx
    mov  edx, OFFSET msgIndent
    call PutStr
    pop  edx
    mov  esi, ebx
pad:
    cmp  esi, edx
    jae  pad_done
    mov  al, ' '
    cmp  BYTE PTR [esi], 9      ; 原始碼是 Tab 就也印 Tab，^ 才會對齊
    jne  put_pad
    mov  al, 9
put_pad:
    call PutChar
    inc  esi
    jmp  pad
pad_done:
    cmp  ecx, MAX_SHOW
    jbe  carets
    mov  ecx, MAX_SHOW
carets:
    mov  al, '^'
    call PutChar
    loop carets
    call PutCrlf
    ret
ShowSourceLine ENDP

; =====================================================================
PrintHint PROC USES eax ecx edx
; 印出 "Hint: valid tokens are Ncu ncU ..."（從 tokenTable 拿，改表會自動跟著變）
; 修改：無
; =====================================================================
    mov  edx, OFFSET msgHint
    call PutStr
    mov  ecx, 0                 ; ECX = opcode
L1: mov  al, cl
    call PutOpName
    mov  al, ' '
    call PutChar
    inc  ecx
    cmp  ecx, NUM_OPS
    jb   L1
    call PutCrlf
    ret
PrintHint ENDP

; =====================================================================
PutOpName PROC USES eax edx
; 印出某個指令的 NCU 寫法（從 tokenTable 拿，所以改對應表時這裡會自動跟著變）
; 輸入：AL = opcode
; 修改：無
; =====================================================================
    movzx eax, al
    lea  edx, [eax+eax*2]       ; EDX = op * 3（LEA 拿來做乘法）
    add  edx, OFFSET tokenTable
    mov  al, [edx]
    call PutChar
    mov  al, [edx+1]
    call PutChar
    mov  al, [edx+2]
    call PutChar
    ret
PutOpName ENDP

; =====================================================================
WriteAsmFile PROC USES eax ecx edx
; 把 outBuf 寫成 outPath
; 輸入：outBuf、outPtr、outPath
; 輸出：檔案；螢幕印出 "examples\hello.ncu: 106 tokens -> 59 operations"
; 修改：無（失敗時結束程式，例如 -o 指定的資料夾不存在）
; =====================================================================
    mov  edx, OFFSET outPath
    call CreateOutputFile       ; Irvine：EAX = file handle
    cmp  eax, INVALID_HANDLE_VALUE
    je   write_err
    mov  outHandle, eax

    mov  edx, OFFSET outBuf
    mov  ecx, outPtr
    sub  ecx, OFFSET outBuf     ; ECX = 內容長度
    call WriteToFile            ; Irvine：寫入 ECX 個 bytes
    mov  eax, outHandle
    call CloseFile

    ; "examples\hello.ncu: 106 tokens -> 59 operations"
    mov  edx, OFFSET srcPath
    call PutStr
    mov  edx, OFFSET msgStat1
    call PutStr
    mov  eax, tokenCount
    call PutDec
    mov  edx, OFFSET msgStat2
    call PutStr
    mov  eax, opCount
    call PutDec
    mov  edx, OFFSET msgStat3
    call PutStr
    call PutCrlf
    ret
write_err:
    mov  edx, OFFSET msgWriteErr
    call PutStr
    mov  edx, OFFSET outPath
    INVOKE Fatal
WriteAsmFile ENDP

; =====================================================================
RunBuild PROC USES eax ecx edx edi
; 執行 ncu_build.bat，把 xxx.asm 組譯 + 連結成 xxx.exe
; 輸入：outBase、outPath、exePath、saveTemps
; 輸出：螢幕印出 "OK: xxx.exe"（失敗時印錯誤並以 exit code 1 結束）
; 修改：無
; 步驟：1. 找到 ncu_build.bat（跟 NcuFuck.exe 放在同一個資料夾）
;       2. 組出命令列
;       3. CreateProcess 執行 → WaitForSingleObject 等它結束
;          → GetExitCodeProcess 拿 exit code（0 = 成功）
;       4. 沒有 --save-temps 就刪掉 .asm（.obj / .log 由 ncu_build.bat 刪）
; =====================================================================
    ; ---- 1. batPath = NcuFuck.exe 所在的資料夾 + "ncu_build.bat" ----
    INVOKE GetModuleFileNameA, 0, ADDR batPath, ARG_SIZE  ; EAX = 路徑長度
    mov  edi, OFFSET batPath
    add  edi, eax               ; EDI = 路徑結尾
find_slash:                     ; 從結尾往回找 '\'
    cmp  edi, OFFSET batPath
    je   got_dir                ; 找不到（不太可能）就整個覆蓋
    dec  edi
    cmp  BYTE PTR [edi], '\'
    jne  find_slash
    inc  edi                    ; EDI = '\' 的下一個字元 = 檔名開頭
got_dir:
    mov  edx, OFFSET batName    ; 把 "NcuFuck.exe" 換成 "ncu_build.bat"
    call AppendStr

    ; ---- 2. cmdLine = cmd.exe /c ""<batPath>" "<outBase>"[ keep]" ----
    mov  edi, OFFSET cmdLine
    mov  edx, OFFSET cmdPrefix
    call AppendStr
    mov  edx, OFFSET batPath
    call AppendStr
    mov  edx, OFFSET strQSQ
    call AppendStr
    mov  edx, OFFSET outBase
    call AppendStr
    mov  edx, OFFSET strQ
    call AppendStr
    cmp  saveTemps, 1           ; --save-temps → 多傳一個 keep
    jne  close_cmd
    mov  edx, OFFSET strKeep
    call AppendStr
close_cmd:
    mov  edx, OFFSET strQ
    call AppendStr

    ; ---- 3. 執行並等它結束 ----
    mov  startInfo.cb, SIZEOF STARTUP_INFO  ; 其他欄位都是 0
    INVOKE CreateProcessA, 0, ADDR cmdLine, 0, 0, 1, 0, 0, 0,
           ADDR startInfo, ADDR procInfo
    test eax, eax               ; EAX = 0 代表失敗
    jz   proc_err

    INVOKE WaitForSingleObject, procInfo.hProcess, INFINITE
    INVOKE GetExitCodeProcess, procInfo.hProcess, ADDR exitCode
    INVOKE CloseHandle, procInfo.hProcess   ; 用完的 handle 要還給系統
    INVOKE CloseHandle, procInfo.hThread

    ; ---- 4. 刪掉中間檔 .asm（成功失敗都刪，除非 --save-temps）----
    cmp  saveTemps, 1
    je   check_exit
    INVOKE DeleteFileA, ADDR outPath
check_exit:
    cmp  exitCode, 0
    jne  build_err

    mov  edx, OFFSET msgOK      ; "OK: hello.exe"
    call PutStr
    mov  edx, OFFSET exePath
    call PutStr
    call PutCrlf
    ret

proc_err:
    cmp  saveTemps, 1
    je   proc_msg
    INVOKE DeleteFileA, ADDR outPath
proc_msg:
    mov  edx, OFFSET msgProcErr
    call PutStr
    mov  edx, OFFSET batPath
    INVOKE Fatal
build_err:
    mov  edx, OFFSET msgBuildErr
    INVOKE Fatal
RunBuild ENDP

; =====================================================================
; Emit 系列：把文字加到 outBuf 的尾巴（outPtr 會往後移）
; 都不會改任何暫存器
; =====================================================================

EmitStr PROC USES eax edx edi
; 輸入：EDX = 以 0 結尾的字串
    mov  edi, outPtr
L1: mov  al, [edx]
    cmp  al, 0
    je   done
    mov  [edi], al
    inc  edx
    inc  edi
    jmp  L1
done:
    mov  outPtr, edi
    ret
EmitStr ENDP

EmitDec PROC USES edx
; 輸入：EAX = 無號整數
    call NumToStr
    call EmitStr
    ret
EmitDec ENDP

EmitCrlf PROC USES edx
    mov  edx, OFFSET strCrlf
    call EmitStr
    ret
EmitCrlf ENDP

END main
