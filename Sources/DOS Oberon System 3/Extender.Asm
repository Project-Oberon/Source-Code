; ******************************************************************************
; Extender.asm ARD 19.08.93
;
; This module defines all the descriptortables, interrupttables, switches then to protected mode
; and installs the loader.
; A flat 32-bit-memory model is assumed.
; No Paging
; ******************************************************************************
 
			NAME	Extender
			
; MACROS
	PrepIDT MACRO offset
		MOV EAX, dword ptr Code32
		ADD EAX, offset
		MOV EDX, EAX
		SHR EDX, 16
	ENDM

	GoReal1 MACRO
		PUSH DS
		PUSH ES
		PUSH FS
		PUSH GS
		PUSH SS	; Push old stack segment. Could be a coroutine stack segment
		CLI
		MOV AX, Data16Sel
		MOV SS, AX
		MOV EAX, CR0
		AND EAX, 7FFFFFFEH
		MOV CR0, EAX
		db 0EBH	; Flush prefetchqueue
		db 0
	ENDM
	
	GoReal2 MACRO
		MOV AX, CS
		MOV ES, AX
		MOV FS, AX
		MOV GS, AX
		MOV DS, AX
		MOV SS, AX
		LIDT qword ptr RealIDT
		MOV dword ptr ProtSP, ESP
		MOV SP, RealSP
	ENDM
	
	GoPM MACRO
		CLI
		CMP byte ptr kbint, 1
		JE BackTrap
		JMP Back
	ENDM
	
	GoPM2 MACRO
		LIDT qword ptr ProtIDT
		MOV RealSP, SP
		MOV ESP, dword ptr ProtSP
;		MOV EAX, CR3
;		MOV CR3, EAX
		MOV EAX, CR0
		OR EAX, 80000001H
		MOV CR0, EAX
		db 0EBH	; Flush prefetchqueue
		db 0
	ENDM

	GoPM3 MACRO
		MOV AX, word ptr Data32Sel
		MOV SS, AX
		POP SS	; Pop original stack segment. Could be a coroutine stack segment
		POP GS
		POP FS
		POP ES
		POP DS
	ENDM
	
	HWICall MACRO off
		db 60h		; PUSHA
		db 9AH		; CALL Code16Sel: Intoffset
		dw offset off
		dw 0
		dw Code16Sel
		db 61h			; POPA
		db 0CFH		; IRET
	ENDM

; CONSTANTS
	IDTEntries	EQU	128
	GDTEntries	EQU	6	; Null, CodeExt, DataExt, Code, Data, LDT
	LDTEntries	EQU	128	; 128 stacks for coroutines

	Limit16	EQU	0FFFFh	; Size in Bytes
	LimitLDT	EQU	LDTEntries*8 -1	; Size in Bytes
	IntCallSize	EQU	256	; Size of interruptcalls at the beginning of code32
	
	BufSize	EQU	4096
	RegSize	EQU	36
	IntOff	EQU	20
	RegOff	EQU	24
	
;	EnableProt	EQU	80000001H	; For entering Protected mode & paging
;	EnableReal	EQU	7FFFFFFEH	; For entering Real mode & no paging
 
; GDT-SELECTORS
	Null	EQU	0h	; Requested priv. level = 0
	Code16Sel	EQU	8h	; Nr. 1
	Data16Sel	EQU	10h	; Same segment
	Code32Sel	EQU	18h	; Nr. 2
	Data32Sel	EQU	20h	; Same segment
	LDTSel	EQU	28h
	
; Register offsets
	AXReg	EQU	0
	CXReg	EQU	2
	DXReg	EQU	4
	BXReg	EQU	6
	SPReg	EQU	8
	BPReg	EQU	10
	SIReg	EQU	12
	DIReg	EQU	14
	Flags	EQU	16
	CSReg	EQU	20
	SSReg	EQU	24
	DSReg	EQU	28
	ESReg	EQU	32
 
	.386p						; enables 386 pm instructions
 
; *************************************************************
; CODE SEGMENT 16-BIT
; *************************************************************
	Code16	SEGMENT BYTE PUBLIC 'CODE' USE16
	ORG 100h	; Because of PSP
	ASSUME	CS: Code16, DS: Code16, ES: Code16, SS: Code16
 
	Oberon	PROC	FAR	 ; Entry Point
		
		; ************************************
		; Get environment variables
		; ************************************
		
		; ************************************
		; Get segment size
		; ************************************
		MOV AX, DS:[2Ch]	; get segment address
		MOV FS, AX
		XOR EBX, EBX
		XOR EDX, EDX
		XOR EAX, EAX
memwhile: MOV AL, FS:[EBX]
		INC EBX
		CMP AL, 0
		JE memend
		CMP AL, 'O'
		JNE memwhile
		MOV AL, FS:[EBX]
		CMP AL, 'B'
		JNE memwhile
		INC EBX
		ADD EBX, 4
		MOV AL, FS:[EBX]
		INC EBX
		CMP AL, 'M'
		JNE memwhile
		MOV AL, FS:[EBX]
		CMP AL, 'E'
		JNE memwhile
		JMP memread
	
memend: MOV AL, FS:[EBX]
		CMP AL, 0
		JNE memwhile
		MOV word ptr omemsize, 3C00h	; default = 15 MB extended memory
		JMP readpath
	
memread: MOV AL, FS:[EBX]
		INC EBX
		CMP AL, '='
		JNE memread
memread1: MOV AL, FS:[EBX]
		INC EBX
		CMP AL, ' '
		JE memread1
		CMP AL, 0
		JE readpath
		IMUL EDX, 10
		SUB AL, '0'
		ADD EDX, EAX
		MOV word ptr omemsize, DX
		JMP memread1

		; ************************************
		; Get path
		; ************************************
readpath: XOR ESI, ESI
		XOR EDI, EDI
		XOR EDX, EDX
		MOV DI, offset pathname
while1: MOV AL, FS:[ESI]
		INC ESI
		CMP AL, 0
		JE end1
		CMP AL, 'O'
		JNE while1
		MOV AL, FS:[ESI]
		CMP AL, 'B'
		JNE while1
		INC ESI
		ADD ESI, 4
		JMP read

end1: MOV AL, FS:[ESI]
		CMP AL, 0
		JNE while1
		JMP pathread

read: MOV AL, FS:[ESI]
		INC ESI
	CMP AL, ' '
	JE read
	CMP AL, '='
	JE read1
	JMP while1
read1: MOV AL, FS:[ESI]
		INC ESI
		CMP AL, ' '
		JE read1
		CMP AL, 0
		JE slash
		MOV [EDI], AL
		INC EDI
		JMP read1
slash:	MOV byte ptr [EDI], 0
		MOV AH, 3Bh
		MOV DX, offset pathname
		CMP byte ptr [EDX+1], ':'
		JNE wrongPath
		AND byte ptr [EDX], 5Fh
		INT 21h
		JC Error
		CMP byte ptr [EDI-1], '\'
		JE pathread
		MOV byte ptr [EDI], '\'
		INC EDI

pathread: 
		MOV byte ptr [EDI], 0
	
		;**********************************
		;Set Disk Parameters (HACK !!!!!!!)
		;**********************************
		
		MOV AX, 351Eh
		INT 21h
		MOV word ptr diskoff, BX
		MOV word ptr diskseg, ES
	
		XOR EBX, EBX
		MOV BX, offset disktable
		MOV byte ptr [EBX], 0DFh
		MOV byte ptr [EBX+1], 2h
		MOV byte ptr [EBX+2], 25h
		MOV byte ptr [EBX+3], 2h
		MOV byte ptr [EBX+4], 9
		MOV byte ptr [EBX+5], 2Ah
		MOV byte ptr [EBX+6], 0FFh
		MOV byte ptr [EBX+7], 50h
		MOV byte ptr [EBX+8], 0F6h
		MOV byte ptr [EBX+9], 0Fh
		MOV byte ptr [EBX+10], 8
		MOV byte ptr [EBX+11], 4Fh
		MOV byte ptr [EBX+12], 80h
	
		MOV AX, DS
		MOV ES, AX
		
		MOV AX, 251Eh
		MOV DX, offset disktable
		INT 21h
		
		;*****************************************************************
		; Reset segments and free not used memory
		; Set stack
		;*****************************************************************
		MOV AX, CS
		MOV DS, AX
		MOV SS, AX
		MOV ES, AX
		MOV FS, AX
		MOV GS, AX
		; Set realmode stack --> SP := EOP + 2k (Stacksize = 2k)
		MOV AX, offset EOP
		ADD AX, 1
		AND AX, 0FFFEH	; Align 2 bytes
		ADD AX, 800H
		MOV SP, AX
		; Free not used Memory
		SHR AX, 4
		INC AX
		MOV BX, AX
		MOV AH, 4AH						; Resize Block
		INT 21H
		MOV dword ptr count, 0	; Init Blockcounter

		;*****************************************************************
		; Get Memory part 1
		;*****************************************************************
		MOV AH, 48H	; Get memory for IntCalls
		MOV BX, 10H
		INT 21H
		JC Error
		MOVZX EAX, AX
		SHL EAX, 4
		MOV dword ptr Code32, EAX
		MOV SI, offset calls	; Transfer Intcalls to Code32:0
		MOVZX ESI, SI
		MOV EDI, dword ptr Code32
		SHR EDI, 4
		MOV ES, DI													; SEGMENT CHANGE
		MOV EDI, 0
		MOV ECX, IntCallSize
		CLD
		REP MOVSB
		
		;*****************************************************************
		; Get paging memory and prepare pages
		;*****************************************************************
		MOV AH, 48H	; Get memory for pages
		MOV BX, 400H	; 16 kb
		INT 21H
		JC Error
		MOVZX EAX, AX
		SHL EAX, 4
		MOV dword ptr Pagebase, EAX
pg2:	MOV EBX, EAX
		AND EBX, 0FFFH
		JZ pg1
		ADD EAX, 16
		JMP pg2
pg1: MOV CR3, EAX	; page address MOD 4096 = 0
		SHR EAX, 4
		MOV FS, AX
		SHL EAX, 4
		MOV EBX, 0
		ADD EAX, 1007H	; page dir
		MOV FS:[EBX], EAX
		ADD EAX, 1000H
		MOV FS:[EBX+4], EAX
		
		MOV ECX, 2	; page dir
		MOV EBX, 8H
		MOV EAX, 0H
pg6:	CMP ECX, 400H
		JGE pg5
		MOV FS:[EBX], EAX
		ADD EBX, 4
		INC ECX
		JMP pg6
		
pg5:		MOV ECX, 0	; page table
		MOV EBX, 1000H
		MOV EAX, 7
pg4:	CMP ECX, 800H
		JGE pg3
		MOV FS:[EBX], EAX
		ADD EAX, 1000H
		ADD EBX, 4
		INC ECX
		JMP pg4
		
pg3: MOV EAX, 0FFFFFFFFH	; reset CR2
		MOV CR2, EAX	
		MOV EAX, 1000H
		MOV dword ptr FS:[EAX], 6	; first page not available, NIL-Check
		
		;*****************************************************************
		; Patch jumps
		; Build IDT.
		; Build LDT.
		; Fill in first 16 entries in IDT.
		; ****************************************************************
		; Patch jump
		MOV AX, CS
		MOV ES, AX	; Restore ES from above													; SEGMENT CHANGE
		MOV word ptr Patch8, AX
		MOV word ptr Patch9, AX
		MOV word ptr Patch10, AX
		MOV word ptr Patch11, AX
		MOV word ptr Patch12, AX
		MOV word ptr Patch13, AX
		MOV word ptr Patch14, AX
		MOV word ptr Patch15, AX
		MOV word ptr Patch112, AX
		MOV word ptr Patch113, AX
		MOV word ptr Patch114, AX
		MOV word ptr Patch115, AX
		MOV word ptr Patch116, AX
		MOV word ptr Patch117, AX
		MOV word ptr Patch118, AX
		MOV word ptr Patch119, AX
		MOV word ptr Patch4, AX
		MOV EAX, dword ptr Code32	; System trap handler
		ADD EAX, 65 
		MOV dword ptr Patch2, EAX
		
		; Build LDT
		XOR EBX, EBX
		MOV BX, offset LDTTable
		MOV word ptr [EBX], 0ffh	; Limit[15 .. 0]
		MOV word ptr [EBX+2], 0	; Base[15 .. 0] 
		MOV byte ptr [EBX+4], 0	; Base[23 .. 16]
		MOV byte ptr [EBX+5], 96h	; Type = 6, DPL = 00
		MOV byte ptr [EBX+6], 40h	; G = 0, D = 1, 
		MOV byte ptr [EBX+7], 0	; Base[31 .. 24]
		; Now that one is built, copy into rest.
		MOV SI, offset LDTTable
		MOV DI, (offset LDTTable + 8)
		MOV CX, (LDTEntries - 1) * 4
		CLD
		REP MOVSW
		
		; Build IDT
		XOR EBX, EBX
		MOV EAX, dword ptr Code32
		ADD EAX, 88
		MOV EDX, EAX
		SHR EDX, 16
		MOV BX, offset IDTTable
		MOV word ptr [EBX], AX	; Offset[15 .. 0] --> IRET
		MOV word ptr [EBX+2], Code32Sel
		MOV byte ptr [EBX+4], 00h; WordCnt = 0
		MOV byte ptr [EBX+5], 8Eh; Type = E, DPL = 00
		MOV word ptr [EBX+6], DX ; Offset[31 .. 16]
		; Now that one is built, copy into rest.
		MOV SI, offset IDTTable
		MOV DI, (offset IDTTable + 8)
		MOV CX, (IDTEntries - 1) * 4
		CLD
		REP MOVSW

		PrepIDT 0
		MOV word ptr [EBX], AX				; Interrupt 0H, division by zero
		MOV word ptr [EBX+6], DX
		
		PrepIDT 26
		MOV word ptr [EBX+8], AX				; Interrupt 1H, breakpoint
		MOV word ptr [EBX+14], DX
		
		PrepIDT 65
		MOV word ptr [EBX+24], AX						; Interrupt 3H, trap 24
		MOV word ptr [EBX+30], DX
		
		PrepIDT 13
		MOV word ptr [EBX+32], AX						; Interrupt 4H, overflow
		MOV word ptr [EBX+38], DX
		
		PrepIDT 0
		MOV word ptr [EBX+40], AX						; Interrupt 5H, not used
		MOV word ptr [EBX+46], DX
		MOV word ptr [EBX+48], AX						; Interrupt 6H, not used
		MOV word ptr [EBX+54], DX
		
		PrepIDT 54
		MOV word ptr [EBX+56], AX						; Interrupt 7H, float
		MOV word ptr [EBX+62], DX
		
		PrepIDT 89
		MOV word ptr [EBX+64], AX						; Interrupt 8H, double fault
		MOV word ptr [EBX+70], DX

		PrepIDT 106
		MOV word ptr [EBX+72], AX						; Interrupt 9H, 
		MOV word ptr [EBX+78], DX
		
		PrepIDT 116
		MOV word ptr [EBX+80], AX						; Interrupt AH
		MOV word ptr [EBX+86], DX

		PrepIDT 126
		MOV word ptr [EBX+88], AX						; Interrupt BH
		MOV word ptr [EBX+94], DX

		PrepIDT 136
		MOV word ptr [EBX+96], AX						; Interrupt CH
		MOV word ptr [EBX+102], DX

		PrepIDT 40
		MOV word ptr [EBX+104], AX;					 ; Interrupt DH, general protection
		MOV word ptr [EBX+110], DX
		
;		PrepIDT 156
		PrepIDT 40
		MOV word ptr [EBX+112], AX						; Interrupt EH, page fault
		MOV word ptr [EBX+118], DX

		PrepIDT 166
		MOV word ptr [EBX+120], AX						; Interrupt FH
		MOV word ptr [EBX+126], DX
		
		PrepIDT 0
		MOV word ptr [EBX+216], AX						 ; Interrupt 1BH
		MOV word ptr [EBX+222], DX
		MOV word ptr [EBX+280], AX						 ; Interrupt 23H
		MOV word ptr [EBX+286], DX
		MOV word ptr [EBX+288], AX						 ; Interrupt 24H
		MOV word ptr [EBX+294], DX

		PrepIDT 176
		MOV word ptr [EBX+896], AX						; Interrupt 70H
		MOV word ptr [EBX+902], DX

		PrepIDT 186
		MOV word ptr [EBX+904], AX						; Interrupt 71H
		MOV word ptr [EBX+910], DX

		PrepIDT 196
		MOV word ptr [EBX+912], AX						; Interrupt 72H
		MOV word ptr [EBX+918], DX

		PrepIDT 206
		MOV word ptr [EBX+920], AX						; Interrupt 73H
		MOV word ptr [EBX+926], DX

		PrepIDT 216
		MOV word ptr [EBX+928], AX						; Interrupt 74H
		MOV word ptr [EBX+934], DX

		PrepIDT 226
		MOV word ptr [EBX+936], AX						; Interrupt 75H
		MOV word ptr [EBX+942], DX

		PrepIDT 236
		MOV word ptr [EBX+944], AX						; Interrupt 76H
		MOV word ptr [EBX+950], DX

		PrepIDT 246
		MOV word ptr [EBX+952], AX						; Interrupt 77H
		MOV word ptr [EBX+958], DX
		; Prepare Interruptcalls in 32-bit-Segment
		JMP LoadCode
	calls:
		db 58H	; POP EAX (0)
		db 59H	; POP ECX
		db 5AH	; POP EDX
		db 68H	; PUSH 6
		dd 6
		db 52H	; PUSH EDX
		db 51H	; PUSH ECX
		db 50H	; PUSH EAX
		db 0EBH ; JMP 52
		db 52
		
		db 58H	; POP EAX	(13)
		db 59H	; POP ECX
		db 5AH	; POP EDX
		db 68H	; PUSH 7
		dd 7
		db 52H	; PUSH EDX
		db 51H	; PUSH ECX
		db 50H	; PUSH EAX
		db 0EBH ; JMP 39
		db 39
		
;		db 58H	; POP EAX	(26)		; New interrupthandling code for debug, resp. NIL check
		db 90H
		db 58H	; POP EAX
		db 59H	; POP ECX
		db 5AH	; POP EDX
		db 68H	; PUSH 2
		dd 2
		db 52H	; PUSH EDX
		db 51H	; PUSH ECX
		db 50H	; PUSH EAX
		db 0EBH ; JMP 25
		db 25
		
		db 58H	; POP EAX	(40)
		db 58H	; POP EAX
		db 59H	; POP ECX
		db 5AH	; POP EDX
		db 68H	; PUSH 4
		dd 4
		db 52H	; PUSH EDX
		db 51H	; PUSH ECX
		db 50H	; PUSH EAX
		db 0EBH ; JMP 11
		db 11
		
		db 60h	; PUSHA	(54)
		db 9AH	; CALL	Intoffset		; New interrupthandling code for floats
		dw 0
		dw 0
		dw Code32Sel
		db 61h	; POPA
		db 0CFH ; IRET
		db 90h	; NOP
		
		db 09AH	; CALL System.Trap (65)
		dd 0
		dw Code32Sel
		db 0BCH	; MOV ESP, StackOrigin (72)
		dd 0
		db 68H	; PUSH Flags (77)
		dw 2020H								; Bits 1 and 9 set
		dw 0
		db 0EH	; PUSH CS (82)
		db 68H	; PUSH Offset (83)
		dd 0
		db 0CFH	; IRET (88)
		
;		HWICall Inter8
		db 60h		; PUSHA		(89)
		db 9AH		; CALL Code16Sel: Intoffset
		dw offset Inter8
		dw 0
		dw Code16Sel
		db 61h			; POPA		(97)replace with CALL S32:Handler --> 7 Bytes
		db 0CFH		; IRET
		db 90H		; NOP
		db 90H		; NOP
		db 90H		; NOP
		db 90H		; NOP
		db 90H		; NOP
		db 61h			; POPA
		db 0CFH		; IRET
		
		HWICall Inter9	; (106)
		HWICall Inter10
		HWICall Inter11
		HWICall Inter12
		HWICall Inter13
		HWICall Inter14
		HWICall Inter15
		HWICall Inter112
		HWICall Inter113
		HWICall Inter114
		HWICall Inter115
		HWICall Inter116
		HWICall Inter117
		HWICall Inter118
		HWICall Inter119
		
		; ****************************************************************
		; INSTALL HW-INTERRUPT HANDLER
		; ****************************************************************

	Inter8: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint8
		dw offset Jumppoint8
	Patch8: dw 0
	Jumppoint8: GoReal2 
		INT 8h
		GoPM
		
	Inter9: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint9
		dw offset Jumppoint9
	Patch9: dw 0
	Jumppoint9: GoReal2 
		INT 9h
		GoPM 
		
	Inter10: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint10
		dw offset Jumppoint10
	Patch10: dw 0
	Jumppoint10: GoReal2 
		INT 0Ah
		GoPM 
		
	Inter11: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint11
		dw offset Jumppoint11
	Patch11: dw 0
	Jumppoint11: GoReal2 
		INT 0Bh
		GoPM 
		
	Inter12: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint12
		dw offset Jumppoint12
	Patch12: dw 0
	Jumppoint12: GoReal2 
		INT 0Ch
		GoPM 
		
	Inter13: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint13
		dw offset Jumppoint13
	Patch13: dw 0
	Jumppoint13: GoReal2 
		INT 0Dh
		GoPM 
		
	Inter14: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint14
		dw offset Jumppoint14
	Patch14: dw 0
	Jumppoint14: GoReal2 
		INT 0Eh
		GoPM 
		
	Inter15: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint15
		dw offset Jumppoint15
	Patch15: dw 0
	Jumppoint15: GoReal2 
		INT 0Fh
		GoPM 
		
	Inter112: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint112
		dw offset Jumppoint112
	Patch112: dw 0
	Jumppoint112: GoReal2 
		INT 70H
		GoPM 
		
	Inter113: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint113
		dw offset Jumppoint113
	Patch113: dw 0
	Jumppoint113: GoReal2 
		INT 71h
		GoPM 
		
	Inter114: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint114
		dw offset Jumppoint114
	Patch114: dw 0
	Jumppoint114: GoReal2 
		INT 72h
		GoPM 
		
	Inter115: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint115
		dw offset Jumppoint115
	Patch115: dw 0
	Jumppoint115: GoReal2 
		INT 73h
		GoPM 
		
	Inter116: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint116
		dw offset Jumppoint116
	Patch116: dw 0
	Jumppoint116: GoReal2 
		INT 74h
		GoPM 
		
	Inter117: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint117
		dw offset Jumppoint117
	Patch117: dw 0
	Jumppoint117: GoReal2 
		INT 75h
		GoPM 
		
	Inter118: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint118
		dw offset Jumppoint118
	Patch118: dw 0
	Jumppoint118: GoReal2 
		INT 76h
		GoPM 
		
	Inter119: GoReal1
		db 0EAH	; JMP FAR ptr Jumppoint119
		dw offset Jumppoint119
	Patch119: dw 0
	Jumppoint119: GoReal2 
		INT 77h
		GoPM 
		
	Back: CLI
		GoPM2 
		db 0EAH	; JMP FAR ptr Jumppoint
		dw offset Jumppointa
		dw Code16Sel
	Jumppointa: GoPM3 
		STI
		db 66h
		RET
		
	BackTrap: MOV byte ptr kbint, 0
		CLI
		GoPM2 
		db 0EAH	; JMP FAR ptr Jumppoint
		dw offset Jumppointb
		dw Code16Sel
	Jumppointb: GoPM3 
		POP ECX ;;
		POP ECX ;;
		POPAD
		POP EAX ;;
		POP EBX ;;
		POP ECX
		db 66h
		PUSH 24

		PUSH ECX		; 'flags'
		PUSH EBX		; 'seg'
		PUSH EAX		; 'adr'
		STI
		db 66h
		db 67h
		db 0EAH	; JMP System.Trap (65)
Patch2:
		dd 0
		dw Code32Sel
		
		; --------------------------------------------
		; *** Traphandler will be set with Kernel.Install ***
		; --------------------------------------------
	
	LoadCode:
		; ****************************************************************
		; Test wether Highmem.Sys is available, install A20, get extended mem.block
		; ****************************************************************
		INT 11H									; Check environment
		AND AL, 2
		JNZ Co
		MOV EAX, CR0									; No Coproc., set Emulation-bit
		OR EAX, 4
		MOV CR0, EAX
Co:	MOV AX, 4300h 
		INT 2FH
		CMP AL, 80H
		JNE NoHighMem
		MOV AX, 4310H
		INT 2FH
		MOV word ptr xmsaddr, BX						; SEGMENT CHANGE
		MOV word ptr xmsaddr+2, ES; Get Startaddress of driver
		MOV AH, 5													; Activate A20
		CALL dword ptr xmsaddr
		CMP AX, 1
		JNE XMSErr
		MOV AH, 8													; Get free Mem.size
		CALL dword ptr xmsaddr
		MOV word ptr MemSize, AX
		MOV DI, word ptr omemsize
		CMP DI, AX
		JA minmem
		MOV AX, DI																; Take minimum of wanted and avail. memory
		MOV word ptr MemSize, AX
minmem:
		MOV DX, AX														; Get free Mem.block
		MOV AH, 9
		CALL dword ptr xmsaddr
		CMP AX, 1
		JNE XMSErr
		MOV word ptr EMBHandle, DX; Save Handle
		MOV AH, 0CH
		CALL dword ptr xmsaddr; Get linear address
		CMP AX, 1
		JNE XMSErr
		MOV word ptr HighStart, BX
		MOV word ptr HighStart+2, DX
 
		; ****************************************************************
		; READ FILE-INFORMATION
		; ****************************************************************
		MOV AH, 3Dh														; Open file named Loader.obj
		MOV AL, 2
		MOV DX, offset loadername
		INT 21h
		JC Error
		MOV Handle, AX

		MOV AH, 3Fh														; Read 34 bytes from file into buffer
		MOV BX, Handle											; Tag and filename read
		MOV CX, 34
		MOV DX, offset buffer
		INT 21h
		JC Error

		MOV AH, 3Fh														; Read 146 bytes from file into buffer
		MOV BX, Handle																	; All read up to CONSTANTS
		MOV CX, 146
		MOV DX, offset buffer
		INT 21h
		JC Error
		MOV EAX, dword ptr buffer[17]	; Get information about sizes
		MOV dword ptr DataS, EAX
		MOV AX, word ptr buffer[21]	; Get information about sizes
		MOV Const, AX
		MOV EAX, dword ptr buffer[23]	; Get information about sizes
		MOV dword ptr CodeS, EAX
		MOV AX, word ptr buffer[43]	; Get information about entries
		MOV Entry1, AX
		MOV AX, word ptr buffer[47]	; Get information about entries
		MOV Entry2, AX
		MOV AX, word ptr buffer[51]	; Get information about entries
		MOV Entry3, AX
		MOV AX, word ptr buffer[55]	; Get information about entries
		MOV Entry4, AX
		MOV AX, word ptr buffer[59]	; Get information about entries
		MOV Entry5, AX
		MOV AX, word ptr buffer[63]	; Get information about entries
		MOV Entry6, AX
		MOV AX, word ptr buffer[67]	; Get information about entries
		MOV Entry7, AX
		MOV AX, word ptr buffer[114]	; Get information about addresses
		MOV Link1, AX
		MOV AX, word ptr buffer[118]	; Get information about addresses
		MOV Link2, AX
		MOV AX, word ptr buffer[122]	; Get information about addresses
		MOV Link3, AX
		MOV AX, word ptr buffer[126]	; Get information about addresses
		MOV Link4, AX
		MOV AX, word ptr buffer[130]	; Get information about addresses
		MOV Link5, AX
		MOV AX, word ptr buffer[134]	; Get information about addresses
		MOV Link6, AX
		MOV AX, word ptr buffer[138]	; Get information about addresses
		MOV Link7, AX
		MOV AX, word ptr buffer[142]	; Get information about addresses
		MOV Link8, AX
		; ****************************************************************
		; ALL INFO READ
		; TRANSFER CODE TO CODE32
		; BUILD GDT.
		; Get Memory part 2
		; ****************************************************************
		MOVZX EBX, Const	; Get memory for Loader: DataS + Const + CodeS
		ADD EBX, dword ptr DataS
		ADD EBX, dword ptr CodeS
		SHR EBX, 4
		INC BX
		MOV AH, 48H
		INT 21H
		JC Error
		MOVZX EAX, AX
		SHL EAX, 4
		MOV dword ptr Start, EAX
		MOV AH, 48H	; Get memory for Interrupt transfer space
		MOV BX, 10H	; 256 bytes
		INT 21H
		JC Error
		MOVZX EAX, AX
		SHL EAX, 4
		MOV dword ptr IntTransfer, EAX
		MOV AX, 5801H	; Set strategie
		MOV BX, 2	; last fit
		INT 21H
		MOV AH, 48H	; Get memory for Stack
		MOV BX, 1000H
		INT 21H
		JC Error
		MOVZX EAX, AX
		SHL EAX, 4
		MOV dword ptr StackAdr, EAX
		
		; entry 0 --> Null
		MOV AX, offset GDTTable
		MOVZX EAX, AX
		MOV dword ptr [EAX], 0
		MOV dword ptr [EAX+4], 0
		ADD EAX, 8
		; entry 1 ---> Code16 descriptor
		MOV CX, CS
		MOV DX, CX
		SHR DX, 12
		SHL CX, 4
		MOV word ptr [EAX], Limit16; Limit[15 .. 0]
		MOV [EAX+2], CX	; Base[15 .. 0]
		MOV [EAX+4], DL	; Base[23 .. 16]
		MOV byte ptr [EAX+5], 9Ah; P=1, DT1=1, DPL = 0, TYPE = rx
		MOV byte ptr [EAX+6], 00h; G=0, D=0, 0, AVL=0, Limit[19 .. 16]
		MOV byte ptr [EAX+7], DH; Base[31 .. 24]
		ADD EAX, 8
		; entry 2 ---> Data16 descriptor
		MOV word ptr [EAX], Limit16; Limit[15 .. 0]
		MOV [EAX+2], CX	; Base[15 .. 0]
		MOV [EAX+4], DL ; Base[23 .. 16]
		MOV byte ptr [EAX+5], 92h; P=1, DT1=1, DPL = 0, TYPE = rw
		MOV byte ptr [EAX+6], 00h; G=0, D=0, 0, AVL=0, Limit[19 .. 16]
		MOV byte ptr [EAX+7], DH; Base[31 .. 24]
		ADD EAX, 8
		; entry 3 ---> Code32 descriptor
		MOV DI, word ptr omemsize
		SHR DI, 2
		ADD DI, 256	; Plus lower MB 
		MOV word ptr [EAX], DI; Limit[15 .. 0]
		MOV word ptr [EAX+2], 0	; Base[15 .. 0]
		MOV byte ptr [EAX+4], 0	; Base[23 .. 16]
		MOV byte ptr [EAX+5], 09Ah; P=1, DT1=1, DPL = 0, TYPE = rx
		MOV byte ptr [EAX+6], 0C0h; G=1, D=1, 0, AVL=0, Limit[19 .. 16]
		MOV byte ptr [EAX+7], 0; Base[31 .. 24]
		ADD EAX, 8
		; entry 4 ---> Data32 descriptor
		MOV word ptr [EAX], DI; Limit[15 .. 0]
		MOV word ptr [EAX+2], 0	; Base[15 .. 0]
		MOV byte ptr [EAX+4], 0	; Base[23 .. 16]
		MOV byte ptr [EAX+5], 092h; P=1, DT1=1, DPL = 0, TYPE = rw
		MOV byte ptr [EAX+6], 0C0h; G=1, D=1, 0, AVL=0, Limit[19 .. 16]
		MOV byte ptr [EAX+7], 0; Base[31 .. 24]
		ADD EAX, 8
		; entry 5 ---> LDT
		XOR EDX, EDX
		XOR EBX, EBX
		MOV DX, CS
		SHL EDX, 4
		MOV BX, offset LDTTable
		ADD EBX, EDX
		MOV word ptr [EAX], LimitLDT; Limit[15 .. 0]
		MOV word ptr [EAX+2], BX	; Base[15 .. 0]
		SHR EBX, 16
		MOV byte ptr [EAX+4], BL	; Base[23 .. 16]
		MOV byte ptr [EAX+5], 082h; P=1, DT1=0, DPL = 0, TYPE = LDT
		MOV byte ptr [EAX+6], 0h; G=0, D=don't care, AVL=0, Limit[19 .. 16]
		MOV byte ptr [EAX+7], BH	; Base[31 .. 24]
		
		; ****************************************************************
		; Read Data from Loaderfile
		; ****************************************************************

		MOV AH, 3Fh																		; Read constants and code and put them into Code32
		MOV BX, Handle
		MOVZX ECX, word ptr Const
		ADD ECX, dword ptr CodeS
		MOV EDX, dword ptr DataS; Let space for glob. vars
		MOV EDI, dword ptr Start
		SHR EDI, 4
		MOV DS, DI													; SEGMENT CHANGE
		INT 21h
		MOV DX, CS													; SEGMENT CHANGE
		MOV DS, DX
		JC Error
		MOV AH, 3EH
		MOV BX, Handle
		INT 21h													; Close File
 
		MOV EDI, dword ptr Start
		SHR EDI, 4
		MOV FS, DI													; SEGMENT CHANGE
		MOV EBX, dword ptr DataS
		MOVZX ECX, word ptr Const
		ADD EBX, ECX
		ADD EBX, 017H							; Put right address into CALL 0000:00000000
		;********************************************
		; 0EH for old compiler with normal ENTER-EXIT
		; 13H for new compiler with PUSH-MOV-SUB protocol
		; 17H for system
		;********************************************
		MOV byte ptr FS:[EBX], 9Ah	; Call instruction
		MOV word ptr FS:[EBX+1], offset StartInt	; Byte ordering
		MOV word ptr FS:[EBX+3], 0
		MOV word ptr FS:[EBX+5], Code16Sel				; ProtModeCall: Descriptor
		
		MOV EBX, BufSize
		ADD EBX, RegSize					 ; Put right address into heapAdr
		MOV EAX, dword ptr HighStart	
		MOV dword ptr FS:[EBX], EAX
		MOV dword ptr FS:[EBX+8], 0		; Put right address into BufBegin;
		MOV EAX, 0A0000H								 ; Put right address into Display;
		MOV dword ptr FS:[EBX+12], EAX
		MOVZX EAX, word ptr MemSize				; Put heapSize. Must be ZX !!
		SHL EAX, 10
		MOV dword ptr FS:[EBX+16], EAX
		MOV EAX, dword ptr IntTransfer			; Put right address into IntTransfer;
		MOV dword ptr FS:[EBX+20], EAX

		XOR EAX, EAX
		XOR ESI, ESI
		MOV AX, offset pathname
		MOV SI, 36
	copystr: CMP byte ptr [EAX], 0
		JE copied
		MOV CL, [EAX]
		MOV byte ptr FS:[EBX+ESI], CL
		INC ESI
		INC EAX
		JMP copystr
	copied: MOV byte ptr FS:[EBX+ESI], 0
	
		MOV EAX, dword ptr Start
		SHR EAX, 4			
		MOV word ptr FS:[EBX+100], AX			 ; Put DS;
		MOV word ptr FS:[EBX+102], AX			 ; Put ES;
		
		MOV EAX, dword ptr Code32
		MOV dword ptr FS:[EBX+104], EAX			 ; Put OldSegment;
		
		MOV EAX, CR3
		MOV dword ptr FS:[EBX+108], EAX			 ; Put PageDir;

		MOV EAX, dword ptr Start				 ; Set DTA
		SHR EAX, 4
		MOV DS, AX													; SEGMENT CHANGE
		MOV DX, 2048
		MOV AH, 1AH
		INT 21H
		MOV AX, CS													; SEGMENT CHANGE
		MOV DS, AX

		; INSTALL TYPE DESCS
		; Typedesc not necessary. No typetests, no typeguards, no typeextensions
		; Attention: Garbage collection
 
		; Fixups
		MOV EAX, dword ptr DataS
		MOVZX ECX, word ptr Const
		ADD EAX, ECX								; Codestart
 
		; Patch jump to 32-bit segment
		MOV dword ptr Patch3, EAX
		MOV EDI, dword ptr Start
		ADD dword ptr Patch3, EDI
		
		MOV ECX, dword ptr DataS					; 'Static Base'
		ADD ECX, dword ptr Start
	Start1:													; Fixup of global data
		MOVZX EDI, word ptr Link1
		ADD EDI, EAX
		MOV BX, word ptr FS:[EDI]
		MOVSX ESI, word ptr FS:[EDI+2]	; Address
		ADD ESI, ECX
		MOV dword ptr FS:[EDI], ESI
		MOV Link1, BX
		CMP BX, 0
		JNZ Start1

		MOVZX EDX, word ptr Entry2
		SUB EDX, 4
	Start2:													; Fixup of global procedure
		MOVZX EDI, Link2
		MOV ECX, EDI
		ADD EDI, EAX
		MOV BX, word ptr FS:[EDI]
		MOVSX ESI, word ptr FS:[EDI+2]	; procnr
		CMP ESI, 0
		JGE L1
		MOVZX ESI, word ptr Entry2
		ADD ESI, EAX
		ADD ESI, dword ptr Start
		JMP L11
L1: MOV ESI, EDX
		SUB ESI, ECX
 L11: MOV dword ptr FS:[EDI], ESI
		MOV Link2, BX
		CMP BX, 0
		JNZ Start2
		
		MOVZX EDX, word ptr Entry3
		SUB EDX, 4
	Start3:													; Fixup of global procedure
		MOVZX EDI, Link3
		MOV ECX, EDI
		ADD EDI, EAX
		MOV BX, word ptr FS:[EDI]
		MOVSX ESI, word ptr FS:[EDI+2]	; procnr
		CMP ESI, 0
		JGE L2
		MOVZX ESI, word ptr Entry3
		ADD ESI, EAX
		ADD ESI, dword ptr Start
		JMP L22
L2: MOV ESI, EDX
		SUB ESI, ECX
 L22: MOV dword ptr FS:[EDI], ESI
		MOV Link3, BX
		CMP BX, 0
		JNZ Start3
		
		MOVZX EDX, word ptr Entry4
		SUB EDX, 4
	Start4:													; Fixup of global procedure
		MOVZX EDI, Link4
		MOV ECX, EDI
		ADD EDI, EAX
		MOV BX, word ptr FS:[EDI]
		MOVSX ESI, word ptr FS:[EDI+2]	; procnr
		CMP ESI, 0
		JGE L3
		MOVZX ESI, word ptr Entry4
		ADD ESI, EAX
		ADD ESI, dword ptr Start
		JMP L33
L3: MOV ESI, EDX
		SUB ESI, ECX
 L33: MOV dword ptr FS:[EDI], ESI
		MOV Link4, BX
		CMP BX, 0
		JNZ Start4
		
		MOVZX EDX, word ptr Entry1
		SUB EDX, 4
	Start5:													; Fixup of global procedure
		MOVZX EDI, Link5
		MOV ECX, EDI
		ADD EDI, EAX
		MOV BX, word ptr FS:[EDI]
		MOVSX ESI, word ptr FS:[EDI+2]	; procnr
		CMP ESI, 0
		JGE L4
		MOVZX ESI, word ptr Entry1
		ADD ESI, EAX
		ADD ESI, dword ptr Start
		JMP L44
L4: MOV ESI, EDX
		SUB ESI, ECX
 L44: MOV dword ptr FS:[EDI], ESI
		MOV Link5, BX
		CMP BX, 0
		JNZ Start5
		
		MOVZX EDX, word ptr Entry5
		SUB EDX, 4
	Start6:													; Fixup of global procedure
		MOVZX EDI, Link6
		MOV ECX, EDI
		ADD EDI, EAX
		MOV BX, word ptr FS:[EDI]
		MOVSX ESI, word ptr FS:[EDI+2]	; procnr
		CMP ESI, 0
		JGE L5
		MOVZX ESI, word ptr Entry5
		ADD ESI, EAX
		ADD ESI, dword ptr Start
		JMP L55
L5: MOV ESI, EDX
		SUB ESI, ECX
 L55: MOV dword ptr FS:[EDI], ESI
		MOV Link6, BX
		CMP BX, 0
		JNZ Start6
		
		MOVZX EDX, word ptr Entry7
		SUB EDX, 4
	Start7:													; Fixup of global procedure
		MOVZX EDI, Link7
		MOV ECX, EDI
		ADD EDI, EAX
		MOV BX, word ptr FS:[EDI]
		MOVSX ESI, word ptr FS:[EDI+2]	; procnr
		CMP ESI, 0
		JGE L6
		MOVZX ESI, word ptr Entry7
		ADD ESI, EAX
		ADD ESI, dword ptr Start
		JMP L66
L6: MOV ESI, EDX
		SUB ESI, ECX
 L66: MOV dword ptr FS:[EDI], ESI
		MOV Link7, BX
		CMP BX, 0
		JNZ Start7
		
		MOVZX EDX, word ptr Entry6
		SUB EDX, 4
	Start8:													; Fixup of global procedure
		MOVZX EDI, Link8
		MOV ECX, EDI
		ADD EDI, EAX
		MOV BX, word ptr FS:[EDI]
		MOVSX ESI, word ptr FS:[EDI+2]	; procnr
		CMP ESI, 0
		JGE L7
		MOVZX ESI, word ptr Entry6
		ADD ESI, EAX
		ADD ESI, dword ptr Start
		JMP L77
L7: MOV ESI, EDX
		SUB ESI, ECX
 L77: MOV dword ptr FS:[EDI], ESI
		MOV Link8, BX
		CMP BX, 0
		JNZ Start8
		
		JMP Cont
	Error:
		PUSH EAX

		; *************************************************************
		; Free extended memory
		; *************************************************************
		MOV AH, 6													; Reset A20
		CALL dword ptr xmsaddr
		MOV AH, 0DH														; Unlock Extended memory
		MOV DX, word ptr EMBHandle
		CALL dword ptr xmsaddr
		MOV AH, 0AH														; Free Extended memory
		MOV DX, word ptr EMBHandle
		CALL dword ptr xmsaddr
		
		MOV AX, 0900h
		MOV DX, offset ErrMsg
		INT 21h
		POP EDX
		ADD DL, 30H
		MOV AH, 2H
		INT 21H
		MOV AX, 4C00H
		INT 21H
		RET
		
	Cont:
; ChangeInterrupt 1BH and 23H and 24H
		MOV AH, 35H
		MOV AL, 23H
		INT 21H
		AND EBX, 0FFFFh
		MOV AX, ES:[EBX]													; SEGMENT CHANGE
		MOV word ptr ctrlc, AX
		MOV byte ptr ES:[EBX], 0CFH; disable Ctrl-C
		
		MOV byte ptr kbint, 0	; Change 23H
		MOV AH, 35H
		MOV AL, 1BH
		INT 21H
		MOV word ptr ctrlboff, BX
		MOV word ptr ctrlbseg, ES													; SEGMENT CHANGE
		MOV DX, offset CtrlBrk
		MOV AH, 25H
		MOV AL, 1BH
		INT 21H
		
		MOV AH, 35H										; Change 24H
		MOV AL, 24H
		INT 21H
		MOV word ptr critoff, BX
		MOV word ptr critseg, ES													; SEGMENT CHANGE
		MOV DX, offset CritError
		MOV AH, 25H
		MOV AL, 24H
		INT 21H
		
		MOV EAX, dword ptr IntTransfer	; Init count
		SHR EAX, 4
		MOV GS, AX													; SEGMENT CHANGE
		MOV byte ptr GS:0, 0

		; Load GDT																		
		MOV word ptr ProtIDT[0], (GDTEntries*8 - 1)
		MOV AX, CS
		MOV BX, AX
		SHL AX, 4
		SHR BX, 12
		ADD AX, offset GDTTable
		ADC BX, 0
		MOV word ptr ProtIDT[2], AX
		MOV word ptr ProtIDT[4], BX
		LGDT qword ptr ProtIDT
		; Load IDTR
		MOV word ptr ProtIDT[0], (IDTEntries * 8 - 1)
		MOV AX, CS
		MOV BX, AX
		SHL AX, 4
		SHR BX, 12
		ADD AX, offset IDTTable
		ADC BX, 0
		MOV word ptr ProtIDT[2], AX
		MOV word ptr ProtIDT[4], BX
		MOV word ptr RealIDT[0], 3FFH; RealIDT: Limit = 1000 bytes, start at 0000:0000
		MOV word ptr RealIDT[2], 0
		MOV word ptr RealIDT[4], 0
		
		CLI
		LIDT qword ptr ProtIDT
		MOV ECX, dword ptr Start										; Place to put the StackOrigin
		ADD ECX, BufSize
		ADD ECX, RegSize
		ADD ECX, 4
		MOV EDX, dword ptr Code32									; Get code start

		; Switch to protected mode
;		MOV EAX, CR3
;		MOV CR3, EAX
		MOV EAX, CR0
		OR EAX, 80000001H
		MOV CR0, EAX
		JMP Flush1
	Flush1:
		db 0EAH					; JMP FAR ptr Jumppoint1
		dw offset Jumppoint1
		dw Code16Sel
	Jumppoint1:
		; Load LDT with zero
		MOV AX, Null
		LLDT AX
 
		; Load Stack
		MOV RealSP, SP
		MOV EAX, dword ptr StackAdr
		ADD EAX, 10000H ; Stackorigin := StackAdr + 64k
		MOV dword ptr temp [0], EAX						; SetStack
		MOV word ptr temp [4], Data32Sel
		LSS ESP, fword ptr temp [0]
		XOR EBX, EBX
		MOV BX, word ptr Data32Sel
		MOV DS, BX													; SEGMENT CHANGE
		MOV FS, BX
		MOV ES, BX
		MOV GS, BX
		ADD EDX, 73
		MOV dword ptr [EDX], EAX						; Set StackOrigin in IntRoutine
		MOV dword ptr [ECX], EAX						; Set StackOrigin in Loader
		STI
		db 67h
		db 66h
		db 0EAh ; JMP FAR Code32Sel:Codestart
	Patch3:
		dd 0
		dw Code32Sel
		RET
	Oberon	ENDP
	
	NoHighMem:
		MOV AX, 0900h
		MOV DX, offset MemMsg
		INT 21H
		JMP Quit
		
	wrongPath:
		MOV AX, 0900h
		MOV DX, offset PathMsg
		INT 21H
		JMP Quit
		
	XMSErr:
		MOV AX, 0900h
		MOV DX, offset XMSMsg
		INT 21H
		MOV DL, BL
		SHR DL, 4
		ADD DL, 30H
		MOV AX, 200H
		INT 21H
		MOV DL, BL
		AND DL, 0FH
		ADD DL, 30H
		MOV AX, 200H
		INT 21H
		
		
	Quit:
		MOV SP, word ptr RealSP
		MOV AX, 4C00H
		INT 21H
		RET
		
		; ****************************************************************
		; CTRL-Brk-INTERRUPTHANDLING PROCEDURE
		; ****************************************************************
	CtrlBrk :
		PUSH EAX
		MOV byte ptr CS:kbint, 1
		MOV AL, 20H
		OUT 20H, AL
		POP EAX
		IRET
		
		; ****************************************************************
		; CTRL-Brk-INTERRUPTHANDLING PROCEDURE
		; ****************************************************************
	CritError :
		PUSH EAX
		MOV byte ptr CS:kbint, 2
		MOV AL, 20H
		OUT 20H, AL
		POP EAX
		IRET
		
		; ****************************************************************
		; SW-INTERRUPTHANDLING PROCEDURES
		; Don't save regs and flags
		; SW ints are controlled interrupts
		; ****************************************************************
	StartInt PROC	FAR
		PUSH EBP	; procedure frame
		MOV EBP, ESP
		
		PUSH DS	; save segment registers
		PUSH ES
		PUSH FS
		PUSH GS
		
		MOV SI, Data16Sel	; FS used for variable access
		MOV FS, SI
		MOV ESI, SS:[EBP+RegOff]	; effective address of registers
		MOV AX, Data32Sel
		MOV DS, AX
		MOV AL, SS:[EBP+IntOff]
		MOV byte ptr FS:Inter, AL	; save interrupt number
		MOV BX, offset Patch1
		MOV FS:[BX+1], AL	; PATCH CODE!!!!
		MOV AX, word ptr DS:[ESI+AXReg]	; get register values
		MOV BX, word ptr DS:[ESI+BXReg]
		MOV CX, word ptr DS:[ESI+CXReg]
		MOV DX, word ptr DS:[ESI+DXReg]
		MOV DI, word ptr DS:[ESI+DIReg]
		PUSH word ptr DS:[ESI+SIReg]	; save values of SI, DS, ES
		POP word ptr FS:saveSI
		PUSH word ptr DS:[ESI+ESReg]
		POP word ptr FS:saveES
		PUSH word ptr DS:[ESI+DSReg]
		POP word ptr FS:saveDS
		
		MOV dword ptr FS:ROff, ESI	; save value of DS:SI for later access
		
		CLI	; switch to real mode
		MOV SI, Data16Sel
		MOV DS, SI
		MOV ES, SI
		MOV FS, SI
		MOV GS, SI
		MOV SS, SI
		MOV ESI, CR0
		AND ESI, 7FFFFFFEH
		MOV CR0, ESI
		db 0EBH
		db 0
		db 0EAH			; JMP FAR ptr Jumppoint4
		dw offset Jumppoint4
	Patch4:
		dw 0
	Jumppoint4:
		MOV SI, CS	; set up realmode stack and variable acces  through FS
		MOV SS, SI
		MOV FS, SI
		LIDT qword ptr FS:RealIDT
		MOV dword ptr FS:ProtSP, ESP
		MOV SP, word ptr FS:RealSP
		STI
		
		MOV SI, word ptr FS:saveDS	; get saved values for DS, ES and SI
		MOV DS, SI
		MOV SI, word ptr FS:saveES
		MOV ES, SI
		MOV SI, word ptr FS:saveSI
		
		CMP byte ptr FS:Inter, 98; IF IntNr. = 98 --> own System.Quit-Routine
		JE SysQuit
		CMP byte ptr FS:Inter, 99; IF IntNr. = 99 --> own GetMemoryRoutine
		JE GetMem
		
Patch1:	INT 21h	; Call interrupt
		
		PUSH DS	; save results
		PUSH SI
		PUSHF
		
		MOV ESI, dword ptr FS:ROff
		SHR ESI, 4
		MOV DS, SI
		MOV ESI, dword ptr FS:ROff
		AND ESI, 0Fh
		
		POP DS:[ESI+Flags]	; get results
		POP DS:[ESI+SIReg]
		POP DS:[ESI+DSReg]
		MOV DS:[ESI+AXReg], AX
		MOV DS:[ESI+CXReg], CX
		MOV DS:[ESI+DXReg], DX
		MOV DS:[ESI+BXReg], BX
		MOV DS:[ESI+SPReg], SP	; meaningless
		MOV DS:[ESI+BPReg], BP	; meaningless
		MOV DS:[ESI+DIReg], DI
		MOV DS:[ESI+CSReg], CS
		MOV DS:[ESI+SSReg], SS
		MOV DS:[ESI+ESReg], ES
		
		JMP cont3
	GetMem:
		MOV AH, 48H
		INT 21H
		JC Error
		MOVZX EAX, AX
		SHL EAX, 4
		MOV EBX, dword ptr FS:count
		MOV CX, offset FS:Blks
		MOVZX ECX, CX 
		ADD EBX, ECX
		MOV FS:[EBX], EAX
		ADD dword ptr FS:count, 4
		
		MOV ESI, dword ptr FS:ROff
		SHR ESI, 4
		MOV DS, SI
		MOV ESI, dword ptr FS:ROff
		AND ESI, 0Fh
		
		SHR EAX, 4
		MOV DS:[ESI+AXReg], AX			; put result into P.AXReg. HACK!!!
		JMP cont3
	SysQuit:
		MOV AX, 5801H					; Set strategie
		MOV BX, 0							; first fit
		INT 21H
		JC Error
		MOV AH, 49H														; Free Stack
		MOV EBX, dword ptr FS:StackAdr
		SHR EBX, 4
		MOV ES, BX
		INT 21H
		MOV AH, 49H														; Free Code32
		MOV EBX, dword ptr FS:Code32
		SHR EBX, 4
		MOV ES, BX
		INT 21H
		MOV AH, 49H														; Free Start
		MOV EBX, dword ptr FS:Start
		SHR EBX, 4
		MOV ES, BX
		INT 21H
		MOV AH, 49H														; Free Pagebase
		MOV EBX, dword ptr FS:Pagebase
		SHR EBX, 4
		MOV ES, BX
		INT 21H
	Free:
		SUB dword ptr FS:count, 4
		MOV EBX, dword ptr FS:count
		MOV CX, offset FS:Blks
		MOVZX ECX, CX
		ADD EBX, ECX
		MOV EBX, FS:[EBX]
		MOV AH, 49H														; Free Blk
		SHR EBX, 4
		MOV ES, BX
		INT 21H
		CMP dword ptr FS:count, 0
		JNE Free
		MOV AH, 6													; Reset A20
		CALL dword ptr FS:xmsaddr
		CMP AX, 1
		JNE XMSErr
		MOV AH, 0DH														; Unlock Extended memory
		MOV DX, word ptr FS:EMBHandle
		CALL dword ptr FS:xmsaddr
		CMP AX, 1
		JNE XMSErr
		MOV AH, 0AH														; Free Extended memory
		MOV DX, word ptr FS:EMBHandle
		CALL dword ptr FS:xmsaddr
		CMP AX, 1
		JNE XMSErr
		MOV AH, 0H														; Reset Display
		MOV AL, 3H
		INT 10H
		
		MOV AH, 35H														; Reset Ctrl-C
		MOV AL, 23H
		INT 21H
		MOV AX, word ptr FS:ctrlc
		AND EBX, 0FFFFh
		MOV ES:[EBX], AX
		
		MOV AH, 25H														; Reset Disk-Int
		MOV AL, 1EH
		MOV DX, word ptr FS:diskoff
		MOV DS, word ptr FS:diskseg
		INT 21H
		
		MOV AH, 25H														; Reset Ctrl-Break
		MOV AL, 1BH
		MOV DX, word ptr FS:ctrlboff
		MOV DS, word ptr FS:ctrlbseg
		INT 21H
		
		MOV AH, 25H														; Reset Crit Error
		MOV AL, 24H
		MOV DX, word ptr FS:critoff
		MOV DS, word ptr FS:critseg
		INT 21H
		
		MOV AX, CS
		MOV DS, AX
		MOV FS, AX
		MOV GS, AX
		
		MOV AX, 4C00H
		INT 21H
		RET
	cont3:
		CLI	; switch back to protected mode
		LIDT qword ptr FS:ProtIDT
		MOV word ptr FS:RealSP, SP
		MOV ESP, dword ptr FS:ProtSP	; get protected mode stack pointer
;		MOV EAX, CR3
;		MOV CR3, EAX
		MOV EAX, CR0
		OR EAX, 80000001H
		MOV CR0, EAX
		db 0EBH
		db 0
		db 0EAH			; JMP FAR ptr Jumppoint4a
		dw offset Jumppoint4a
		dw Code16Sel
	Jumppoint4a:
		MOV AX, word ptr Data32Sel	; get old stack segment
		MOV SS, AX
		POP GS	; get old segment values
		POP FS
		POP ES
		POP DS
		POP EBP
		
		STI
		db 66h
		RET
	StartInt ENDP
 
		; ****************************************************************
		; GLOBAL DATA OF EXTENDER
		; ****************************************************************
 
		pathname	db 64 DUP(0)
		loadername	db 'loader.obj', 0
		IDTTable	db IDTEntries*8 DUP (?); define x bytes size init with ?
		GDTTable	db GDTEntries*8 DUP (?)
		LDTTable	db LDTEntries*8 DUP (?)
		ProtIDT	db 8 DUP (?)
		RealIDT	db 8 DUP (?)
		Code32	dd 1 DUP (?)
		Pagebase	dd 1 DUP (?)
		Start		dd 1 DUP (?) ; Start of loadercode
		help		dd 1 DUP (?)
		oldEBP	dd 1 DUP (?)
		Inter		db 1 DUP (?)
		temp	db 10 DUP (?)
		saveSI	dw 1 DUP (?)
		saveDS	dw 1 DUP (?)
		saveES	dw 1 DUP (?)
		ROff	dd 1 DUP (?)
		Link1	dw 1 DUP (?)
		Link2	dw 1 DUP (?)
		Link3	dw 1 DUP (?)
		Link4	dw 1 DUP (?)
		Link5	dw 1 DUP (?)
		Link6	dw 1 DUP (?)
		Link7	dw 1 DUP (?)
		Link8	dw 1 DUP (?)
		Entry1	dw 1 DUP (?)
		Entry2	dw 1 DUP (?)
		Entry3	dw 1 DUP (?)
		Entry4	dw 1 DUP (?)
		Entry5	dw 1 DUP (?)
		Entry6	dw 1 DUP (?)
		Entry7	dw 1 DUP (?)
		Handle	dw 1 DUP (?)
		Const	dw 1 DUP (?)
		DataS	dd 1 DUP (?)
		CodeS	dd 1 DUP (?)
		buffer	db 172 DUP (0)
		ProtSP	dd 1 DUP (?)
		RealSP	dw 1 DUP (?)
		xmsaddr	dd 1 DUP (?)
		EMBHandle	dw 1 DUP (?)
		HighStart	dd 1 DUP (?)
		StackAdr	dd 1 DUP (?)
		IntTransfer	dd 1 DUP (?)
		MemSize	dw 1 DUP (?)	; max. available memory
		omemsize	dw 1 DUP(?)		; memory size read in autoexec.bat
		count	dd 1 DUP (0)
		ctrlc	dw 1 DUP (?)
		ctrlboff	dw 1 DUP (?)
		ctrlbseg	dw 1 DUP (?)
		diskoff	dw 1 DUP (?)
		diskseg	dw 1 DUP (?)
		disktable	db 18 DUP (?)
		critoff	dw 1 DUP (?)
		critseg	dw 1 DUP (?)
		kbint	db 1 DUP (?)
		Blks	dd 50 DUP (?)
		ErrMsg	db 'An error occurred: Nr. $'; Errormessage
		MemMsg	db 'Please load HIMEM.SYS.$'; Errormessage
		XMSMsg	db 'XMS Error: Nr. $'; Errormessage
		PathMsg	db 'Incorrect path in environment variable Oberon. (Use drive:\path) $'; Errormessage
		EOP:
	Code16	ENDS
 
 END Oberon
