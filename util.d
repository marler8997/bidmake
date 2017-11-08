module util;

import core.stdc.string : memmove;

import std.stdio : File, writefln, writeln;
import std.format : format, formattedWrite;
import std.path   : buildPath;
import std.conv : to;
import std.array  : empty, front, popFront;
import std.string : indexOf, lastIndexOf;
import std.process: spawnShell, wait;
import std.traits : isSomeChar, hasMember, isArray;
import std.typecons : Flag, Yes, No;

import utf8;

// a cstring is a null-terminted pointer to characters
alias cstring = char*;
alias const_cstring = const(char)*;
alias immutable_cstring = immutable(char)*;

// a zstring is a standard d string that is also terminated by a null character
alias zstring = char[];
alias const_zstring = const(char)[];
alias immutable_zstring = string;

@property T unconst(T)(const(T) obj)
{
  return cast(T)obj;
}
@property immutable(T) castImmutable(T)(T obj)
{
  return cast(immutable(T))obj;
}

class QuitException : Exception
{
    this() { super(null); }
}
// use "throw quit;" to quit the program without printing exception info
auto quit()
{
    return new QuitException();
}

struct Builder(T, Expander)
{
    static assert(hasMember!(Expander, "expand"), Expander.stringof~" does not have an expand function");

    T[] buffer;
    size_t dataLength;

    @property T[] data() { return buffer[0..dataLength]; }

    T* getRef(size_t index)
    {
        return &buffer[index];
    }

    void ensureCapacity(size_t capacityNeeded)
    {
        if(capacityNeeded > buffer.length)
        {
            this.buffer = Expander.expand!T(buffer, dataLength, capacityNeeded);
        }
    }
    void makeRoomFor(size_t newContentLength)
    {
        ensureCapacity(dataLength + newContentLength);
    }
    T* reserveOne(Flag!"initialize" initialize)
    {
        makeRoomFor(1);
        if(initialize)
        {
            buffer[dataLength] = T.init;
        }
        return &buffer[dataLength++];
    }
    void shrink(size_t newLength) in { assert(newLength < dataLength); } body
    {
        dataLength = newLength;
    }
    void shrinkIfSmaller(size_t newLength)
    {
        if(newLength < dataLength)
        {
            dataLength = newLength;
        }
    }

    static if(__traits(compiles, { T t1; const(T) t2; t1 = t2; }))
    {
        void append(const(T) newElement)
        {
            makeRoomFor(1);
            buffer[dataLength++] = newElement;
        }
        void append(const(T)[] newElements)
        {
            makeRoomFor(newElements.length);
            buffer[dataLength..dataLength+newElements.length] = newElements[];
            dataLength += newElements.length;
        }
    }
    else
    {
        void append(T newElement)
        {
            makeRoomFor(1);
            buffer[dataLength++] = newElement;
        }
        void append(T[] newElements)
        {
            makeRoomFor(newElements.length);
            buffer[dataLength..dataLength+newElements.length] = newElements[];
            dataLength += newElements.length;
        }
    }

    static if(isSomeChar!T)
    {
        void appendf(Args...)(const(char)[] fmt, Args args)
        {
            import std.format : formattedWrite;
            formattedWrite(&append, fmt, args);
        }
        // Only call if the data in this builder will not be modified
        string finalString()
        {
            return cast(string)buffer[0..dataLength];
        }
    }

    void removeAt(size_t index) in { assert(index < dataLength); } body
    {
        if(index < dataLength-1)
        {
            memmove(&buffer[index], &buffer[index+1], T.sizeof * (dataLength-(index+1)));
        }
        dataLength--;
    }
}

// Always expands the to a power of 2 of the initial size.
struct GCDoubler(uint initialSize)
{
    static T[] expand(T)(T[] array, size_t preserveSize, size_t neededSize)
        in { assert(array.length < neededSize); } body
    {
        size_t newSize = (array.length == 0) ? initialSize : array.length * 2;
        while(neededSize > newSize)
        {
            newSize *= 2;
        }
        // TODO: there might be a more efficient way to do this?
        array.length = newSize;
        return array;
    }
}


inout(T) peel(T)(inout(T)[]* array)
{
    if(array.length == 0)
    {
        return typeof((*array)[0]).init;
    }
    auto result = (*array)[0];
    *array = (*array)[1..$];
    return result;
}

bool equalContains(T,U)(T inputRange, U value)
{
    for(; !inputRange.empty; inputRange.popFront())
    {
        if(inputRange.front == value)
        {
            return true;
        }
    }
    return false;
}
bool isContains(T,U)(T inputRange, U value)
{
    for(; !inputRange.empty; inputRange.popFront())
    {
        if(inputRange.front is value)
        {
            return true;
        }
    }
    return false;
}


//--------------------------------------------------------------------
// Process
//--------------------------------------------------------------------
auto tryRun(string command)
{
    writefln("[SHELL] %s", command);
    auto pid = spawnShell(command);
    auto exitCode = wait(pid);
    writeln("-------------------------------------------------------");
    return exitCode;
}
void run(string command)
{
    auto exitCode = tryRun(command);
    if(exitCode)
    {
        writefln("failed with exit code %s", exitCode);
        throw quit;
    }
}

//--------------------------------------------------------------------
// Formatting
//--------------------------------------------------------------------
alias StringSink = scope void delegate(const(char)[]);
struct DelegateFormatter
{
    void delegate(StringSink sink) formatter;
    void toString(StringSink sink) const
    {
        formatter(sink);
    }
}

void putf(T, U...)(T appender, string fmt, U args)
{
    formattedWrite(&appender.put!(const(char)[]), fmt, args);
}

char hexchar(ubyte b) in { assert(b <= 0x0F); } body
{
    return cast(char)(b + ((b <= 9) ? '0' : ('A'-10)));
}
bool isUnreadable(dchar c) pure nothrow @nogc @safe
{
    return c < ' ' || (c > '~' && c < 256);
}
void writeUnreadable(scope void delegate(const(char)[]) sink, dchar c) in { assert(isUnreadable(c)); } body
{
    if(c == '\r') sink("\\r");
    else if(c == '\t') sink("\\t");
    else if(c == '\n') sink("\\n");
    else if(c == '\0') sink("\\0");
    else {
        char[4] buffer;
        buffer[0] = '\\';
        buffer[1] = 'x';
        buffer[2] = hexchar((cast(char)c)>>4);
        buffer[3] = hexchar((cast(char)c)&0xF);
        sink(buffer);
    }
}

void writeEscaped(scope void delegate(const(char)[]) sink, const(char)* ptr, const char* limit)
{
    auto flushPtr = ptr;

    void flush()
    {
        if(ptr > flushPtr)
        {
            sink(flushPtr[0..ptr-flushPtr]);
            flushPtr = ptr;
        }
    }

    for(; ptr < limit;)
    {
        const(char)* nextPtr = ptr;
        dchar c = decodeUtf8(&nextPtr);
        if(isUnreadable(c))
        {
            flush();
            sink.writeUnreadable(c);
        }
        ptr = nextPtr;
    }
    flush();
}
auto escape(const(char)[] str)
{
    struct Formatter
    {
        const(char)* str;
        const(char)* limit;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            sink.writeEscaped(str, limit);
        }
    }
    return Formatter(str.ptr, str.ptr + str.length);
}

auto escape(dchar c)
{
    struct Formatter
    {
        char[4] buffer;
        ubyte size;
        this(dchar c)
        {
            size = encodeUtf8(buffer.ptr, c);
        }
        void toString(scope void delegate(const(char)[]) sink) const
        {
            sink.writeEscaped(buffer.ptr, buffer.ptr + size);
        }
    }
    return Formatter(c);
}

@property auto formatDir(const(char)[] dir)
{
    if(dir.length == 0)
    {
        dir = ".";
    }
    return formatQuotedIfSpaces(dir);
}

// returns a formatter that will print the given string.  it will print
// it surrounded with quotes if the string contains any spaces.
@property auto formatQuotedIfSpaces(T...)(T args) if(T.length > 0)
{
    struct Formatter
    {
        T args;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            bool useQuotes = false;
            foreach(arg; args)
            {
                if(arg.indexOf(' ') >= 0)
                {
                    useQuotes = true;
                    break;
                }
            }

            if(useQuotes)
            {
                sink("\"");
            }
            foreach(arg; args)
            {
                sink(arg);
            }
            if(useQuotes)
            {
                sink("\"");
            }
        }
    }
    return Formatter(args);
}


struct PeeledName
{
    string nextName;
    string rest;
}
auto peelQualifiedName(string qualifiedName)
{
    auto dotIndex = qualifiedName.indexOf(".");
    if(dotIndex > 0)
    {
        return PeeledName(qualifiedName[0..dotIndex], qualifiedName[dotIndex+1..$]);
    }
    return PeeledName(qualifiedName, null);
}

//--------------------------------------------------------------------
// Files
//--------------------------------------------------------------------

// Reads the file into a string, adds a terminating NULL as well
zstring readFile(const(char)[] filename)
{
    auto file = File(filename, "rb");
    auto fileSize = file.size();
    if(fileSize > size_t.max - 1)
    {
        assert(0, format("file \"%s\" is too large %s > %s", filename, fileSize, size_t.max - 1));
    }
    auto contents = new char[cast(size_t)(fileSize + 1)]; // add 1 for '\0'
    auto readSize = file.rawRead(contents).length;
    assert(fileSize == readSize, format("rawRead only read %s bytes of %s byte file", readSize, fileSize));
    contents[cast(size_t)fileSize] = '\0';
    return contents[0..$-1];
}

version(Windows)
{
    enum defaultPathSeparatorChar = '\\';
    bool isPathSeparator(char c)
    {
        return c == '\\' || c == '/';
    }
    size_t findLastPathSeparator(const(char)[] path)
    {
        size_t i = path.length;
        for(;;)
        {
            if(i == 0)
            {
                return 0;
            }
            i--;
            if(path[i] == '/' || path[i] == '\\')
            {
                return i;
            }
        }
    }
    bool containsPathSeperator(const(char)[] path)
    {
        foreach(c; path)
        {
            if(c == '/' || c == '\\')
            {
                return true;
            }
        }
        return false;
    }
}
else
{
    enum defaultPathSeparatorChar = '/';
    bool isPathSeparator(char c)
    {
        return c == '/';
    }
    size_t findLastPathSeparator(const(char)[] path)
    {
        return path.lastIndexOf('/');
    }
    bool containsPathSeperator(const(char)[] path)
    {
        return path.indexOf('/') >= 0;
    }
}

struct DirAndFile
{
    string pathFileCombo;
    size_t dirLimitIndex;
    size_t baseNameIndex;
    this(string pathFileCombo)
    {
        this.pathFileCombo = pathFileCombo;
        auto lastPathSeparator = pathFileCombo.findLastPathSeparator();
        if(lastPathSeparator == -1)
        {
            this.dirLimitIndex = 0;
            this.baseNameIndex = 0;
        }
        else
        {
            this.dirLimitIndex = lastPathSeparator;
            this.baseNameIndex = lastPathSeparator + 1;
        }
    }
    @property dir() const
    {
        return pathFileCombo[0..dirLimitIndex];
    }
    @property base() const
    {
        return pathFileCombo[baseNameIndex..$];
    }
}