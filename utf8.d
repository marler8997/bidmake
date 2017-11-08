module utf8;

import std.stdio : Exception;
import std.format : format;

class Utf8Exception : Exception
{
    this(string msg) pure
    {
        super(msg);
    }
}

enum invalidEndMessage = "input ended with invalid UTF-8 character";

// This method assumes that utf8 points to at least one character
// and that the first non-valid pointer is at the limit pointer
// (this means that utf8 < limit)
dchar decodeUtf8(T)(T** utf8InOut) pure
{
    auto utf8 = *utf8InOut;
    dchar firstByte = *utf8;
    utf8++;
    if((firstByte & 0x80) == 0)
    {
        *utf8InOut = utf8;
        return firstByte;
    }

    if((firstByte & 0x20) == 0)
    {
        utf8++;
        *utf8InOut = utf8;
        return ((firstByte << 6) & 0x7C0) | (*(utf8 - 1) & 0x3F);
    }

    throw new Exception(format("utf8 not fully implemented (firstByte=0x%x)", firstByte));
}

    /*
unittest
{
  void testDecodeUtf8(string s, dchar[] expectedChars...) {
    dchar decoded;
    auto start = s.ptr;
    auto limit = s.ptr + s.length;

    foreach(expected; expectedChars) {
      if(start >= limit) {
        writefln("Expected more decoded utf8 chars but input ended");
        assert(0);
      }
      auto saveStart = start;
      decoded = decodeUtf8(start, limit);
      if(decoded != expected) {
        writefln("Expected '%s' 0x%x but decoded '%s' 0x%x",
            expected, expected, decoded, decoded);
        assert(0);
      }
      start = saveStart;
      decoded = bjoernDecodeUtf8(start, limit);
      if(decoded != expected) {
        writefln("Expected '%s' 0x%x but decoded '%s' 0x%x",
            expected, expected, decoded, decoded);
        assert(0);
      }
      debug writefln("decodeUtf8('%s')", decoded);
    }
  }

  testDecodeUtf8("\u0000", 0x0000);
  testDecodeUtf8("\u0001", 0x0001);

  testDecodeUtf8("\u00a9", 0xa9);
  testDecodeUtf8("\u00b1", 0xb1);
  testDecodeUtf8("\u02c2", 0x02c2);
}
*/

ubyte encodeUtf8(char* dst, dchar c)
{
    if(c < 0x80)
    {
        *dst++ = cast(char)c;
        return 1;
    }
    if(c < 0x800)
    {
        *dst++ = cast(char)(192+c/64);
        *dst++ = cast(char)(128+c%64);
        return 2;
    }
    if(c - 0xd800u < 0x800)
        assert(0, "encodeUtf8 got an invalid value");
    if(c < 0x10000)
    {
        *dst++ = cast(char)(224+c/4096);
        *dst++ = cast(char)(128+c/64%64);
        *dst++ = cast(char)(128+c%64);
        return 3;
    }
    if(c < 0x110000)
    {
        *dst++ = cast(char)(240+c/262144);
        *dst++ = cast(char)(128+c/4096%64);
        *dst++ = cast(char)(128+c/64%64);
        *dst++ = cast(char)(128+c%64);
        return 4;
    }
    assert(0, "encodeUtf8 got a value that was too large");
}