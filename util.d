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
auto tryRun(const(char)[] command)
{
    writefln("[SHELL] %s", command);
    auto pid = spawnShell(command);
    auto exitCode = wait(pid);
    writeln("-------------------------------------------------------");
    return exitCode;
}
void run(const(char)[] command)
{
    auto exitCode = tryRun(command);
    if(exitCode)
    {
        writefln("failed with exit code %s", exitCode);
        throw quit;
    }
}

@property auto formatDir(const(char)[] dir)
{
    if(dir.length == 0)
    {
        dir = ".";
    }
    return formatQuotedIfSpaces(dir);
}

// TODO: probably move this function to mored
//
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

// TODO: probably move this function to "mored"
//
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

// TODO: add my own implementation of buildPath?
// TODO: probably move this path stuff to "mored", more.path?
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