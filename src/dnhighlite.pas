{ dnhighlite — editor/viewer syntax highlighting, a port of the DN OSP
  engine (original/dnossp/highlite.pas) and its DN.HGL rule parser
  (original/dnossp640/MACRO.PAS InitHighLight).

  Rules live in HGL format: "FILES <masks>" sections with comment /
  string / number flags and two keyword banks. A built-in rule set
  (derived from the original dn.hgl, extended with unix file types)
  is used unless <config>/dn.hgl exists — then that file replaces it.

  HglColorLine classifies every byte of a line into hh* classes.
  Unlike the original (strictly per-line), paired comments carry their
  state across lines via StateIn/StateOut. }
unit dnhighlite;

{$mode objfpc}{$H+}

interface

const
  { per-byte classes produced by HglColorLine }
  hhNothing  = 0;   // plain text
  hhNumber   = 1;
  hhString   = 2;
  hhComment  = 3;
  hhSymbol   = 4;   // break characters (punctuation)
  hhKeyword1 = 5;
  hhKeyword2 = 6;

type
  THglPair = record
    A, B: AnsiString;               // paired comment: start / end
  end;

  THglRules = record
    Valid: Boolean;                 // False: no highlighting for this file
    GenFlags: Word;
    HexFlags, DecFlags, OctFlagsQ, OctFlagsO, BinFlags: Word;
    StrFlags: Word;
    CommentStarts: array of AnsiString;  // whole line is a comment (after blanks)
    LineComments: array of AnsiString;   // comment to end of line, anywhere
    PairComments: array of THglPair;     // in-line paired comment
    Keywords1, Keywords2: array of AnsiString;
    { port extension (markdown): a line starting with one of these
      prefixes takes the keyword-1/2 class whole (headers, quotes) }
    LineStart1, LineStart2: array of AnsiString;
  end;

  THlClasses = array of Byte;       // 0-based, one per byte of the line

const
  { special line states besides pair-comment indexes >= 0 and -1 (none):
    the previous line was a LineStart2 item, so an indented following
    line continues it (hard-wrapped markdown list entries) }
  hgsCont2 = -2;

{ rules for a file name (base name, no directory); Valid=False if the
  name matches no FILES section or the section says HIGHLIGHT OFF }
function HglForFile(const FileName: AnsiString): THglRules;
{ classify every byte of s; empty array when R.Valid is False.
  StateIn/StateOut carry an open paired comment across lines (the index
  into R.PairComments, -1 = none) — the original engine was strictly
  per-line and lost multi-line comments; this port tracks them. }
function HglColorLine(const R: THglRules; const s: AnsiString;
                      StateIn: Integer; out StateOut: Integer): THlClasses;
function HglColorLine(const R: THglRules; const s: AnsiString): THlClasses;
{ line-start state for the NEXT line given this line and its state }
function HglNextState(const R: THglRules; const s: AnsiString;
                      StateIn: Integer): Integer;
{ draw one highlighted line at (y,x): w codepoint cells of s starting
  at codepoint offset leftX, padded with spaces; plainPair colors
  unclassified text and the padding }
procedure PutHlLine(y, x: Integer; const s: AnsiString; leftX, w: Integer;
                    const R: THglRules; plainPair: Integer;
                    StateIn: Integer = -1);

implementation

uses
  SysUtils, Classes, dnscreen, dnpanel, dnconfig;

const
  { general flags }
  hoCaseSensitive   = $01;
  hoNoNumbers       = $02;
  hoNoSymbols       = $04;
  hoNoStrings       = $08;
  ho0xPrefixHex     = $10;  //  0x####  C
  hoDollarPrefixHex = $20;  //   $####  Pascal
  hoFloatNumbers    = $40;  //   #.#e#
  hoAllowShortFloat = $80;  //    .#e#

  { number flags (per radix letter: H D Q O B) }
  hoSuffix          = $01;  //   ####x
  hoAmpersandPrefix = $08;  //  &x####
  hoAmpersandText   = $10;  // &x'####'
  hoPrefix          = $20;  //  x'####
  hoPrefixText      = $40;  // x'####'

  { string flags }
  hoEscDoubleQuote   = $01; // \" inside "..."
  hoEscSingleQuote   = $02; // \' inside '...'
  hoHashCharacter    = $04; // #number   (Pascal)
  hoCtrlCharacter    = $08; // ^char     (Pascal)
  hoOctalCharacter   = $10; // octalC
  hoNoSQuotedStrings = $20;
  hoNoDQuotedStrings = $40;
  hoStrictCtrlChar   = $80; // ^char not followed by 0-9/A-Z

type
  TCharSet = set of Char;

const
  HexDigits: TCharSet = ['0'..'9', 'A'..'F', 'a'..'f'];
  DecDigits: TCharSet = ['0'..'9'];
  OctDigits: TCharSet = ['0'..'7'];
  BinDigits: TCharSet = ['0'..'1'];

{ word-break characters: ASCII punctuation and blanks. '_' and bytes
  >= #128 (UTF-8) belong to words, so identifiers never end mid-token. }
function IsBreak(c: Char): Boolean; inline;
begin
  Result := (c < #128) and not (c in ['0'..'9', 'A'..'Z', 'a'..'z', '_']);
end;

{ ------------------------------------------------------------------ }
{ built-in rules: dn.hgl format, ported from original/dnossp with     }
{ unix additions (sh, python, json, makefile masks)                   }
{ ------------------------------------------------------------------ }

const
  BuiltinHgl: array[0..111] of AnsiString = (
    'FILES *.pas;*.pp;*.inc;*.lpr;*.dpr;*.dfm;*.lfm',
    '  CommentString //',
    '  Comment       (* *),{ }',
    '  GeneralFLAGS  32',
    '  StringFLAGS   204',
    '  Keywords1     and,asm,array,begin,case,class,const,constructor,destructor,',
    '  Keywords1     div,do,downto,else,end,except,exports,file,finalization,finally,',
    '  Keywords1     for,function,goto,if,implementation,in,inherited,initialization,',
    '  Keywords1     inline,interface,is,label,library,mod,nil,not,object,of,operator,',
    '  Keywords1     or,out,packed,procedure,program,property,raise,record,repeat,set,',
    '  Keywords1     shl,shr,string,then,threadvar,to,try,type,unit,until,uses,var,',
    '  Keywords1     while,with,xor',
    '  Keywords2     absolute,abstract,assembler,cdecl,default,export,external,far,',
    '  Keywords2     forward,index,interrupt,near,overload,override,private,protected,',
    '  Keywords2     public,published,read,reintroduce,resident,virtual,write',
    'END',
    'FILES *.c;*.h;*.cpp;*.hpp;*.cxx;*.hxx;*.cc;*.m;*.mm',
    '  CommentString //',
    '  Comment       /* */',
    '  GeneralFLAGS  81',
    '  StringFLAGS   3',
    '  Keywords1     auto,bool,break,case,catch,char,class,const,continue,default,',
    '  Keywords1     delete,do,double,else,enum,explicit,extern,false,float,for,friend,',
    '  Keywords1     goto,if,inline,int,long,mutable,namespace,new,nullptr,operator,',
    '  Keywords1     private,protected,public,register,return,short,signed,sizeof,',
    '  Keywords1     static,struct,switch,template,this,throw,true,try,typedef,typeid,',
    '  Keywords1     typename,union,unsigned,using,virtual,void,volatile,wchar_t,while',
    '  Keywords2     #if,#ifdef,#ifndef,#elif,#else,#endif,#define,#undef,#pragma,',
    '  Keywords2     #line,#include,#error,#warning',
    'END',
    'FILES *.sh;*.bash;*.zsh;*.command;.bashrc;.zshrc;.profile',
    '  CommentString #',
    '  GeneralFLAGS  17',
    '  StringFLAGS   3',
    '  Keywords1     if,then,else,elif,fi,for,in,do,done,while,until,case,esac,',
    '  Keywords1     function,select,time,return,break,continue,exit,local,export,',
    '  Keywords1     readonly,declare,set,unset,shift,source,eval,exec,trap,test',
    '  Keywords2     echo,cd,pwd,read,printf,alias,true,false,kill,wait,sudo,grep,',
    '  Keywords2     sed,awk,cat,rm,cp,mv,mkdir,curl,make,git',
    'END',
    'FILES *.py',
    '  CommentString #',
    '  GeneralFLAGS  81',
    '  StringFLAGS   3',
    '  Keywords1     False,None,True,and,as,assert,async,await,break,class,continue,',
    '  Keywords1     def,del,elif,else,except,finally,for,from,global,if,import,in,',
    '  Keywords1     is,lambda,match,nonlocal,not,or,pass,raise,return,try,while,',
    '  Keywords1     with,yield',
    '  Keywords2     self,cls,print,len,range,int,str,float,list,dict,set,tuple,',
    '  Keywords2     type,super,object,isinstance,Exception,ValueError,TypeError',
    'END',
    'FILES makefile;makefile.*;GNUmakefile;*.mak;*.mk',
    '  CommentString #',
    '  GeneralFLAGS  17',
    '  Keywords1     ifdef,ifndef,ifeq,ifneq,else,endif,include,define,endef,export,',
    '  Keywords1     unexport,override,vpath',
    '  Keywords2     .PHONY,.SUFFIXES,.DEFAULT,.PRECIOUS,.SILENT,.EXPORT_ALL_VARIABLES,',
    '  Keywords2     $@,$<,$^,$*,$?',
    'END',
    'FILES *.json',
    '  GeneralFLAGS  65',
    '  StringFLAGS   1',
    '  Keywords1     true,false,null',
    'END',
    'FILES *.cfg;*.ini;*.conf;*.toml;*.desktop;*.service',
    '  CommentStart  ;,#',
    '  CommentString //',
    '  GeneralFLAGS  14',
    'END',
    'FILES *.htm;*.html;*.xml;*.xhtml;*.svg;*.plist',
    '  Comment       <!-- -->',
    '  GeneralFLAGS  2',
    'END',
    'FILES *.sql',
    '  CommentString --',
    '  Comment       /* */',
    '  GeneralFLAGS  64',
    '  StringFLAGS   64',
    '  Keywords1     select,insert,update,delete,from,where,join,inner,left,',
    '  Keywords1     right,outer,cross,on,group,by,order,having,limit,offset,',
    '  Keywords1     union,all,distinct,as,and,or,not,in,is,null,like,between,',
    '  Keywords1     exists,case,when,then,else,end,create,table,index,view,',
    '  Keywords1     drop,alter,add,primary,key,foreign,references,unique,',
    '  Keywords1     default,check,constraint,into,values,set,begin,commit,',
    '  Keywords1     rollback,transaction,grant,revoke,with,explain,vacuum',
    '  Keywords2     int,integer,bigint,smallint,decimal,numeric,float,real,',
    '  Keywords2     double,char,varchar,text,date,time,timestamp,boolean,',
    '  Keywords2     blob,serial,count,sum,avg,min,max,coalesce,cast,now',
    'END',
    'FILES *.yml;*.yaml',
    '  CommentString #',
    '  GeneralFLAGS  64',
    '  Keywords1     true,false,null,yes,no,on,off',
    'END',
    'FILES *.csv;*.tsv',
    '  GeneralFLAGS  64',
    '  StringFLAGS   32',
    'END',
    'FILES *.md;*.markdown;*.mdown',
    '  LineStart1    #',
    '  LineStart2    >,-,+,=,*',
    '  Comment       ``` ```,` `',
    '  GeneralFLAGS  14',
    'END',
    'FILES *.asm;*.s;*.S',
    '  CommentString ;',
    '  HexNumFLAGS   31',
    '  DecNumFLAGS   31',
    '  Keywords1     public,extern,extrn,include,macro,endm,segment,ends,proc,endp,',
    '  Keywords1     end,title,module,code,data,const,equ,global,name,group,assume,org',
    '  Keywords2     if,ifdef,ifndef,elif,else,endif,define,undef,section,global,db,dw,dd,dq',
    'END');

{ ------------------------------------------------------------------ }
{ HGL parser (port of MACRO.PAS InitHighLight)                        }
{ ------------------------------------------------------------------ }

procedure SplitCommas(const s: AnsiString; Dest: TStringList);
var
  item: AnsiString;
  i, start: Integer;
begin
  start := 1;
  for i := 1 to Length(s) + 1 do
    if (i > Length(s)) or (s[i] = ',') then
    begin
      item := Trim(Copy(s, start, i - start));
      if item <> '' then
        Dest.Add(item);
      start := i + 1;
    end;
end;

{ parse one FILES section body into R; Lines[idx] is the first line after
  FILES; on return idx is at the section's END (or past the list) }
procedure ParseSection(Lines: TStringList; var idx: Integer; var R: THglRules);
var
  cs, ls, k1, k2, st1, st2: TStringList;
  pairs: array of THglPair;
  raw, up, val: AnsiString;
  i: Integer;

  function KeyVal(const key: AnsiString): Boolean;
  begin
    Result := Copy(up, 1, Length(key)) = key;
    if Result then
      val := Trim(Copy(raw, Length(key) + 1, MaxInt));
  end;

  procedure MakeValue(var W: Word);
  var
    n, code: Integer;
  begin
    System.Val(val, n, code);
    if (code = 0) and (n >= 0) then
      W := n;
  end;

  procedure MakePairs;
  var
    parts: TStringList;
    j, sp: Integer;
    a, b: AnsiString;
  begin
    parts := TStringList.Create;
    try
      SplitCommas(val, parts);
      for j := 0 to parts.Count - 1 do
      begin
        sp := Pos(' ', parts[j]);
        if sp <= 1 then Continue;
        a := Trim(Copy(parts[j], 1, sp - 1));
        b := Trim(Copy(parts[j], sp + 1, MaxInt));
        if (a = '') or (b = '') then Continue;
        SetLength(pairs, Length(pairs) + 1);
        pairs[High(pairs)].A := a;
        pairs[High(pairs)].B := b;
      end;
    finally
      parts.Free;
    end;
  end;

begin
  cs := TStringList.Create;
  ls := TStringList.Create;
  k1 := TStringList.Create;
  k2 := TStringList.Create;
  st1 := TStringList.Create;
  st2 := TStringList.Create;
  pairs := nil;
  try
    while idx < Lines.Count do
    begin
      raw := Trim(Lines[idx]);
      up := UpperCase(raw);
      if (raw = '') or (raw[1] = ';') then
      begin
        Inc(idx);
        Continue;
      end;
      if (up = 'END') or (Copy(up, 1, 6) = 'FILES ') then
        Break;
      if Copy(up, 1, 6) = 'MACRO ' then
      begin
        { editor macros are not supported: skip to ENDMACRO }
        repeat
          Inc(idx);
        until (idx >= Lines.Count) or
              (UpperCase(Trim(Lines[idx])) = 'ENDMACRO');
      end
      else if KeyVal('COMMENTSTART ') then SplitCommas(val, cs)
      else if KeyVal('COMMENTSTRING ') then SplitCommas(val, ls)
      else if KeyVal('COMMENT ') then MakePairs
      else if KeyVal('KEYWORDS1 ') then SplitCommas(val, k1)
      else if KeyVal('KEYWORDS2 ') then SplitCommas(val, k2)
      else if KeyVal('LINESTART1 ') then SplitCommas(val, st1)
      else if KeyVal('LINESTART2 ') then SplitCommas(val, st2)
      else if KeyVal('GENERALFLAGS ') then MakeValue(R.GenFlags)
      else if KeyVal('HEXNUMFLAGS ') then MakeValue(R.HexFlags)
      else if KeyVal('DECNUMFLAGS ') then MakeValue(R.DecFlags)
      else if KeyVal('OCTONUMFLAGS ') then MakeValue(R.OctFlagsO)
      else if KeyVal('OCTQNUMFLAGS ') then MakeValue(R.OctFlagsQ)
      else if KeyVal('BINNUMFLAGS ') then MakeValue(R.BinFlags)
      else if KeyVal('STRINGFLAGS ') then MakeValue(R.StrFlags)
      else if KeyVal('HIGHLIGHT ') then
        R.Valid := (UpperCase(val) = 'ON') or (UpperCase(val) = 'YES');
      { anything else (editor options like H_LINE, AUTOWRAP) is ignored }
      Inc(idx);
    end;

    { append to whatever DEFAULT may have provided }
    for i := 0 to cs.Count - 1 do
    begin
      SetLength(R.CommentStarts, Length(R.CommentStarts) + 1);
      R.CommentStarts[High(R.CommentStarts)] := cs[i];
    end;
    for i := 0 to ls.Count - 1 do
    begin
      SetLength(R.LineComments, Length(R.LineComments) + 1);
      R.LineComments[High(R.LineComments)] := ls[i];
    end;
    for i := 0 to High(pairs) do
    begin
      SetLength(R.PairComments, Length(R.PairComments) + 1);
      R.PairComments[High(R.PairComments)] := pairs[i];
    end;
    for i := 0 to k1.Count - 1 do
    begin
      SetLength(R.Keywords1, Length(R.Keywords1) + 1);
      R.Keywords1[High(R.Keywords1)] := k1[i];
    end;
    for i := 0 to k2.Count - 1 do
    begin
      SetLength(R.Keywords2, Length(R.Keywords2) + 1);
      R.Keywords2[High(R.Keywords2)] := k2[i];
    end;
    for i := 0 to st1.Count - 1 do
    begin
      SetLength(R.LineStart1, Length(R.LineStart1) + 1);
      R.LineStart1[High(R.LineStart1)] := st1[i];
    end;
    for i := 0 to st2.Count - 1 do
    begin
      SetLength(R.LineStart2, Length(R.LineStart2) + 1);
      R.LineStart2[High(R.LineStart2)] := st2[i];
    end;
  finally
    cs.Free; ls.Free; k1.Free; k2.Free; st1.Free; st2.Free;
  end;
end;

{ uppercase all rule strings once when the language is case-insensitive
  (the original FixHighliteParams); matching then uppercases the line }
procedure NormalizeRules(var R: THglRules);
var
  i: Integer;
begin
  if (R.GenFlags and hoCaseSensitive) <> 0 then Exit;
  for i := 0 to High(R.CommentStarts) do R.CommentStarts[i] := UpperCase(R.CommentStarts[i]);
  for i := 0 to High(R.LineComments) do R.LineComments[i] := UpperCase(R.LineComments[i]);
  for i := 0 to High(R.PairComments) do
  begin
    R.PairComments[i].A := UpperCase(R.PairComments[i].A);
    R.PairComments[i].B := UpperCase(R.PairComments[i].B);
  end;
  for i := 0 to High(R.Keywords1) do R.Keywords1[i] := UpperCase(R.Keywords1[i]);
  for i := 0 to High(R.Keywords2) do R.Keywords2[i] := UpperCase(R.Keywords2[i]);
  for i := 0 to High(R.LineStart1) do R.LineStart1[i] := UpperCase(R.LineStart1[i]);
  for i := 0 to High(R.LineStart2) do R.LineStart2[i] := UpperCase(R.LineStart2[i]);
end;

var
  HglLines: TStringList = nil;      // loaded rule text, built lazily

procedure EnsureHglLines;
var
  f: AnsiString;
  i: Integer;
begin
  if HglLines <> nil then Exit;
  HglLines := TStringList.Create;
  f := ConfigDir + '/dn.hgl';
  if FileExists(f) then
    try
      HglLines.LoadFromFile(f);
      Exit;
    except
      HglLines.Clear;
    end;
  for i := 0 to High(BuiltinHgl) do
    HglLines.Add(BuiltinHgl[i]);
end;

function HglForFile(const FileName: AnsiString): THglRules;
var
  idx: Integer;
  raw, up, masks: AnsiString;
begin
  Result := Default(THglRules);
  if FileName = '' then Exit;
  EnsureHglLines;
  idx := 0;
  while idx < HglLines.Count do
  begin
    raw := Trim(HglLines[idx]);
    up := UpperCase(raw);
    if Copy(up, 1, 6) = 'FILES ' then
    begin
      masks := Trim(Copy(raw, 7, MaxInt));
      Inc(idx);
      if MatchMask(FileName, masks) then
      begin
        Result.Valid := True;
        ParseSection(HglLines, idx, Result);
        NormalizeRules(Result);
        Exit;
      end;
    end
    else if up = 'DEFAULT' then
    begin
      Inc(idx);
      Result.Valid := True;
      ParseSection(HglLines, idx, Result);
    end
    else
      Inc(idx);
  end;
  { no FILES section matched: DEFAULT alone applies if it was present }
  NormalizeRules(Result);
end;

{ ------------------------------------------------------------------ }
{ the classifier (port of highlite.pas Highlites)                     }
{ ------------------------------------------------------------------ }

function HglColorLine(const R: THglRules; const s: AnsiString;
                      StateIn: Integer; out StateOut: Integer): THlClasses;
var
  U: AnsiString;                    // match copy (uppercased if insensitive)
  len: Integer;

  function BreakAt(p: Integer): Boolean; inline;
  begin
    { past-the-end counts as a boundary }
    Result := (p > len) or IsBreak(U[p]);
  end;

  function MatchAt(p: Integer; const pat: AnsiString): Boolean;
  var
    j: Integer;
  begin
    Result := False;
    if (pat = '') or (p + Length(pat) - 1 > len) then Exit;
    for j := 1 to Length(pat) do
      if U[p + j - 1] <> pat[j] then Exit;
    Result := True;
  end;

  { number prefixes/suffixes ('0X', '$', radix letters) always match
    case-insensitively, like the original CheckPattern(..., False) —
    even in case-sensitive languages 0x2A and 0X2A are both numbers }
  function MatchAtCI(p: Integer; const pat: AnsiString): Boolean;
  var
    j: Integer;
  begin
    Result := False;
    if p + Length(pat) - 1 > len then Exit;
    for j := 1 to Length(pat) do
      if UpCase(U[p + j - 1]) <> pat[j] then Exit;
    Result := True;
  end;

  { count of chars from Allowed at p, prefixed/suffixed by literals;
    0 when the shape does not match (the original ParseChars) }
  function ParseChars(p: Integer; const Prefix: AnsiString;
                      const Allowed: TCharSet; const Suffix: AnsiString): Integer;
  var
    j, k: Integer;
  begin
    Result := 0;
    j := p;
    if not MatchAtCI(j, Prefix) then Exit;
    Inc(j, Length(Prefix));
    k := 0;
    while (j <= len) and (U[j] in Allowed) do
    begin
      Inc(j); Inc(k);
    end;
    if k <= 0 then Exit;
    if not MatchAtCI(j, Suffix) then Exit;
    Inc(j, Length(Suffix));
    Result := j - p;
  end;

  function ParseNumber(p, Max: Integer; Mode: Char; Options: Word;
                       const Digits: TCharSet): Integer;
  var
    j: Integer;
  begin
    if ((Options and hoSuffix) <> 0) and (p <= len) and (U[p] in DecDigits) then
    begin
      j := ParseChars(p, '', Digits, Mode);
      if j > Max then Max := j;
    end;
    if (Options and hoAmpersandPrefix) <> 0 then
    begin
      j := ParseChars(p, '&' + Mode, Digits, '');
      if j > Max then Max := j;
    end;
    if (Options and hoAmpersandText) <> 0 then
    begin
      j := ParseChars(p, '&' + Mode + '''', Digits, '''');
      if j > Max then Max := j;
    end;
    if (Options and hoPrefix) <> 0 then
    begin
      j := ParseChars(p, Mode + '''', Digits, '');
      if j > Max then Max := j;
    end;
    if (Options and hoPrefixText) <> 0 then
    begin
      j := ParseChars(p, Mode + '''', Digits, '''');
      if j > Max then Max := j;
    end;
    Result := Max;
  end;

  function ParseFloat(p: Integer): Integer;
  var
    max, j, k: Integer;
  begin
    Result := 0;
    j := p;
    while (j <= len) and (U[j] in DecDigits) do Inc(j);
    if (j = p) and ((R.GenFlags and hoAllowShortFloat) = 0) then Exit;
    max := j - p;
    k := j;
    if (j <= len) and (U[j] = '.') then Inc(j)
    else if j = p then Exit(max);
    if j > k then
    begin
      k := j;
      while (j <= len) and (U[j] in DecDigits) do Inc(j);
      if j = k then Exit(max);
    end;
    max := j - p;
    if (j <= len) and (U[j] in ['e', 'E']) then
    begin
      Inc(j);
      if (j <= len) and (U[j] in ['+', '-']) then Inc(j);
      k := j;
      while (j <= len) and (U[j] in DecDigits) do Inc(j);
      if j > k then max := j - p;
    end;
    Result := max;
  end;

  function CheckNumber(p: Integer): Integer;
  var
    max, j: Integer;
  begin
    if (R.GenFlags and hoFloatNumbers) <> 0 then
      max := ParseFloat(p)
    else
      max := ParseChars(p, '', DecDigits, '');
    if (R.GenFlags and ho0xPrefixHex) <> 0 then
    begin
      j := ParseChars(p, '0X', HexDigits, '');
      if j >= max then max := j;
    end;
    if (R.GenFlags and hoDollarPrefixHex) <> 0 then
    begin
      j := ParseChars(p, '$', HexDigits, '');
      if j >= max then max := j;
    end;
    if R.HexFlags <> 0 then max := ParseNumber(p, max, 'H', R.HexFlags, HexDigits);
    if R.DecFlags <> 0 then max := ParseNumber(p, max, 'D', R.DecFlags, DecDigits);
    if R.OctFlagsQ <> 0 then max := ParseNumber(p, max, 'Q', R.OctFlagsQ, OctDigits);
    if R.OctFlagsO <> 0 then max := ParseNumber(p, max, 'O', R.OctFlagsO, OctDigits);
    if R.BinFlags <> 0 then max := ParseNumber(p, max, 'B', R.BinFlags, BinDigits);
    Result := max;
  end;

  function CheckString(p: Integer): Integer;
  var
    opts: Word;
    j, k: Integer;
    term: Char;
    esc: Boolean;
  begin
    opts := R.StrFlags;
    j := p;
    repeat
      k := 0;
      if (j <= len) and
         (((U[j] = '''') and ((opts and hoNoSQuotedStrings) = 0)) or
          ((U[j] = '"') and ((opts and hoNoDQuotedStrings) = 0))) then
      begin
        term := U[j];
        esc := False;
        k := j + 1;
        while k <= len do
        begin
          if (U[k] = '\') and not esc then
            esc := True
          else if U[k] = term then
          begin
            if not ((term = '"') and ((opts and hoEscDoubleQuote) <> 0) and esc) and
               not ((term = '''') and ((opts and hoEscSingleQuote) <> 0) and esc) then
            begin
              Inc(k);
              Break;
            end;
            esc := False;
          end
          else
            esc := False;
          Inc(k);
        end;
        Dec(k, j);
      end
      else if ((opts and hoHashCharacter) <> 0) and (j <= len) and (U[j] = '#') then
      begin
        k := CheckNumber(j + 1);
        if k > 0 then Inc(k);
      end
      else if ((opts and hoCtrlCharacter) <> 0) and (j <= len) and (U[j] = '^') then
      begin
        if (j + 1 <= len) and (UpCase(U[j + 1]) in ['@'..'_']) and
           (((opts and hoStrictCtrlChar) = 0) or (j + 2 > len) or
            not (UpCase(U[j + 2]) in ['0'..'9', 'A'..'Z'])) then
          k := 2;
      end
      else if ((opts and hoOctalCharacter) <> 0) and (j <= len) and (U[j] in OctDigits) then
      begin
        k := ParseChars(j, '', OctDigits, 'C');
        if k > 0 then Inc(k);
      end;
      Inc(j, k);
    until k = 0;
    Result := j - p;
  end;

  { line comments run to EOL; paired comments end at their close marker
    or at EOL — then OpenPair reports which pair stays open for the
    following lines }
  function CheckComment(p: Integer; out OpenPair: Integer): Integer;
  var
    i, j: Integer;
  begin
    Result := 0;
    OpenPair := -1;
    for i := 0 to High(R.LineComments) do
      if MatchAt(p, R.LineComments[i]) then
        Exit(len - p + 1);
    for i := 0 to High(R.PairComments) do
      if MatchAt(p, R.PairComments[i].A) then
      begin
        j := p + Length(R.PairComments[i].A);
        while (j <= len) and not MatchAt(j, R.PairComments[i].B) do
          Inc(j);
        if j <= len then
          Exit(j + Length(R.PairComments[i].B) - p)
        else
        begin
          OpenPair := i;
          Exit(len - p + 1);
        end;
      end;
  end;

  function CheckKeyword(p: Integer; const List: array of AnsiString): Integer;
  var
    i: Integer;
  begin
    Result := 0;
    for i := 0 to High(List) do
      if (Length(List[i]) > Result) and MatchAt(p, List[i]) then
        Result := Length(List[i]);
  end;

  function CheckEmpty: Boolean;
  var
    i: Integer;
  begin
    Result := True;
    for i := 1 to len do
      if not (U[i] in [' ', #9]) then Exit(False);
  end;

  function CheckStartComment: Boolean;
  var
    p, i: Integer;
  begin
    Result := False;
    p := 1;
    while (p <= len) and (U[p] in [' ', #9]) do Inc(p);
    if p > len then Exit;
    for i := 0 to High(R.CommentStarts) do
      if MatchAt(p, R.CommentStarts[i]) then Exit(True);
  end;

  { markdown headers/quotes: prefix after blanks claims the whole line }
  function CheckLineStart(const Prefixes: array of AnsiString): Boolean;
  var
    p, i: Integer;
  begin
    Result := False;
    p := 1;
    while (p <= len) and (U[p] in [' ', #9]) do Inc(p);
    if p > len then Exit;
    for i := 0 to High(Prefixes) do
      if MatchAt(p, Prefixes[i]) then Exit(True);
  end;

  procedure Fill(p, n: Integer; cls: Byte);
  var
    j: Integer;
  begin
    for j := p to p + n - 1 do
      if (j >= 1) and (j <= len) then
        Result[j - 1] := cls;
  end;

var
  i, max, j, k, op: Integer;
  c, d: Byte;
  atStart: Boolean;                 // 'b' in the original: word boundary
  quoteS, quoteD: Boolean;
begin
  Result := nil;
  StateOut := -1;
  if not R.Valid then Exit;
  if (StateIn > High(R.PairComments)) or (StateIn < hgsCont2) then
    StateIn := -1;
  len := Length(s);
  SetLength(Result, len);
  if len = 0 then
  begin
    { only an open comment survives an empty line; a wrapped markdown
      list item ends at the blank line }
    if StateIn >= 0 then
      StateOut := StateIn;
    Exit;
  end;
  FillChar(Result[0], len, hhNothing);
  if (R.GenFlags and hoCaseSensitive) = 0 then
    U := UpperCase(s)
  else
    U := s;

  i := 1;
  if StateIn >= 0 then
  begin
    { the line opens inside a paired comment: eat up to its close marker }
    while (i <= len) and not MatchAt(i, R.PairComments[StateIn].B) do
      Inc(i);
    if i > len then
    begin
      Fill(1, len, hhComment);
      StateOut := StateIn;
      Exit;
    end;
    Inc(i, Length(R.PairComments[StateIn].B));
    Fill(1, i - 1, hhComment);
  end
  else
  begin
    if CheckEmpty then
    begin
      Fill(1, len, hhSymbol);
      Exit;
    end;
    if CheckStartComment then
    begin
      Fill(1, len, hhComment);
      Exit;
    end;
    if CheckLineStart(R.LineStart1) then
    begin
      Fill(1, len, hhKeyword1);
      Exit;
    end;
    if CheckLineStart(R.LineStart2) then
    begin
      Fill(1, len, hhKeyword2);
      StateOut := hgsCont2;
      Exit;
    end;
    { an indented line right after a LineStart2 item is its hard-wrapped
      continuation: it keeps the item's class (markdown lists) }
    if (StateIn = hgsCont2) and (U[1] in [' ', #9]) then
    begin
      Fill(1, len, hhKeyword2);
      StateOut := hgsCont2;
      Exit;
    end;
  end;

  { quotes count as breaks only when strings are being recognized }
  quoteS := ((R.GenFlags and hoNoStrings) = 0) and
            ((R.StrFlags and hoNoSQuotedStrings) = 0);
  quoteD := ((R.GenFlags and hoNoStrings) = 0) and
            ((R.StrFlags and hoNoDQuotedStrings) = 0);

  atStart := True;
  while i <= len do
  begin
    max := 1;
    if IsBreak(U[i]) or (quoteS and (U[i] = '''')) or (quoteD and (U[i] = '"')) then
      c := hhSymbol
    else
      c := hhNothing;

    if atStart then
    begin
      k := max;
      d := c;
      if (R.GenFlags and hoNoNumbers) = 0 then
      begin
        j := CheckNumber(i);
        if j >= k then begin k := j; d := hhNumber; end;
      end;
      j := CheckKeyword(i, R.Keywords1);
      if j >= k then begin k := j; d := hhKeyword1; end;
      j := CheckKeyword(i, R.Keywords2);
      if j >= k then begin k := j; d := hhKeyword2; end;
      { accept only when the token ends at a word boundary }
      if BreakAt(i + k) or ((k > 0) and BreakAt(i + k - 1)) then
      begin
        max := k;
        c := d;
      end;
    end;

    atStart := False;
    j := CheckComment(i, op);
    if j >= max then
    begin
      max := j;
      c := hhComment;
      atStart := True;
      { an unterminated pair spills into the following lines; anything
        that overrides this match (a longer string) cancels it }
      StateOut := op;
    end;
    if (R.GenFlags and hoNoStrings) = 0 then
    begin
      j := CheckString(i);
      if j >= max then
      begin
        max := j;
        c := hhString;
        atStart := True;
        StateOut := -1;             // a longer string wins over the comment
      end;
    end;
    if c = hhSymbol then
    begin
      atStart := True;
      if (R.GenFlags and hoNoSymbols) <> 0 then
        c := hhNothing;
    end;
    if max < 1 then max := 1;
    Fill(i, max, c);
    Inc(i, max);
  end;
end;

function HglColorLine(const R: THglRules; const s: AnsiString): THlClasses;
var
  dummy: Integer;
begin
  Result := HglColorLine(R, s, -1, dummy);
end;

function HglNextState(const R: THglRules; const s: AnsiString;
                      StateIn: Integer): Integer;
begin
  HglColorLine(R, s, StateIn, Result);
end;

procedure PutHlLine(y, x: Integer; const s: AnsiString; leftX, w: Integer;
                    const R: THglRules; plainPair: Integer;
                    StateIn: Integer);
var
  cls: THlClasses;
  bp, col, runCol, n, stOut: Integer;
  run: AnsiString;
  cur, cl: Byte;

  procedure PairFor(c: Byte; out pair: Integer; out bold: Boolean);
  begin
    bold := False;
    case c of
      hhNumber:   pair := cpSynNumber;
      hhString:   pair := cpSynString;
      hhComment:  begin pair := cpSynComment; bold := True; end;
      hhSymbol:   pair := cpSynSymbol;
      hhKeyword1: begin pair := cpSynKw1; bold := True; end;
      hhKeyword2: begin pair := cpSynKw2; bold := True; end;
    else
      pair := plainPair;
    end;
  end;

  procedure Flush;
  var
    pair: Integer;
    bold: Boolean;
  begin
    if run = '' then Exit;
    PairFor(cur, pair, bold);
    PutStr(y, x + runCol, run, pair, bold);
    run := '';
  end;

begin
  cls := HglColorLine(R, s, StateIn, stOut);
  if cls = nil then
  begin
    PutStr(y, x, Utf8PadRight(Utf8Copy(s, leftX + 1, w), w), plainPair);
    Exit;
  end;
  bp := Utf8BytePos(s, leftX + 1);
  col := 0;
  runCol := 0;
  cur := hhNothing;
  run := '';
  while (bp <= Length(s)) and (col < w) do
  begin
    n := Utf8CharBytes(s, bp);
    cl := cls[bp - 1];
    if (run <> '') and (cl <> cur) then Flush;
    if run = '' then
    begin
      cur := cl;
      runCol := col;
    end;
    run := run + Copy(s, bp, n);
    Inc(bp, n);
    Inc(col);
  end;
  Flush;
  if col < w then
    PutStr(y, x + col, StringOfChar(' ', w - col), plainPair);
end;

initialization

finalization
  HglLines.Free;
end.
