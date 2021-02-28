MODULE In; (* Stream-oriented text input, MR 1992, NW 22.5.93, JG 26.7.93 *)
  IMPORT Texts, Viewers, Oberon, TextFrames;

  VAR Done*: BOOLEAN; S: Texts.Scanner;

PROCEDURE Open*;
  VAR beg, end, time: LONGINT; V: Viewers.Viewer; T: Texts.Text;
BEGIN Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);  Texts.Scan(S);
  IF (S.class = Texts.Char) & (S.c = "^") THEN
    Oberon.GetSelection(T, beg, end, time);
    IF time >= 0 THEN Texts.OpenScanner(S, T, beg); Done := TRUE
      ELSE Done := FALSE
    END
  ELSIF (S.class = Texts.Char) & (S.c = "*") THEN
    V := Oberon.MarkedViewer();
    IF (V.dsc # NIL) & (V.dsc.next IS TextFrames.Frame) THEN
      T := V.dsc.next(TextFrames.Frame).text; Texts.OpenScanner(S, T, 0); Done := TRUE
    ELSE Done := FALSE
    END
  ELSE T := Oberon.Par.text; Texts.OpenScanner(S, T, Oberon.Par.pos); Done := TRUE
  END
END Open;

PROCEDURE Char* (VAR ch: CHAR);
BEGIN
  IF Done THEN ch := S.nextCh; Done := ~S.eot; Texts.Read(S, S.nextCh) END
END Char;

PROCEDURE Int* (VAR i: INTEGER);
BEGIN
  IF Done THEN Texts.Scan(S);
    IF (S.class = Texts.Int) & (MIN(INTEGER) <= S.i) & (S.i <= MAX(INTEGER)) THEN i := SHORT(S.i)
      ELSE Done := FALSE
    END
  END
END Int;

PROCEDURE LongInt* (VAR i: LONGINT);
BEGIN
  IF Done THEN Texts.Scan(S);
    IF S.class = Texts.Int THEN i := S.i ELSE Done := FALSE END
  END
END LongInt;

PROCEDURE Real* (VAR x: REAL);
BEGIN
  IF Done THEN Texts.Scan(S);
    IF S.class = Texts.Real THEN x := S.x
      ELSIF S.class = Texts.Int THEN x := S.i
      ELSE Done := FALSE
      END
  END
END Real;

PROCEDURE LongReal* (VAR y: LONGREAL);
BEGIN
  IF Done THEN Texts.Scan(S);
    IF S.class = Texts.LongReal THEN y := S.y
      ELSIF S.class = Texts.Real THEN y := S.x
      ELSIF S.class = Texts.Int THEN y := S.i
      ELSE Done := FALSE
      END
  END
END LongReal;

PROCEDURE Name* (VAR name: ARRAY OF CHAR);
BEGIN
	IF Done THEN Texts.Scan(S);
      IF S.class = Texts.Name THEN COPY(S.s, name)
      ELSE Done := FALSE
      END
    END
END Name;

PROCEDURE String* (VAR str: ARRAY OF CHAR);
BEGIN
	IF Done THEN Texts.Scan(S);
      IF (S.class = Texts.String) OR (S.class = Texts.Name) THEN COPY(S.s, str)
      ELSE Done := FALSE
      END
   END
END String;

BEGIN Done := FALSE
END In.
