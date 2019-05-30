module bidmake.builtincontractors;

import std.typecons : Flag, Yes, No;
import std.array : appender;
import std.range : ElementType;
import std.path  : buildPath, baseName;
import std.string : startsWith, replace;
import std.format: format;
import std.json : parseJSON, JSONValue;
import std.datetime : SysTime;
import std.file  : exists, remove, timeLastModified, readText;
import std.stdio;

import more.format : putf;
import util : quit, peel, formatQuotedIfSpaces, run, tryRun;
import bidmake.analyzer;

//
// dmd
//
ContractorResult dmdExecute(Contractor contractor, BidmakeFile contractFile, Contract contract, string[] args)
{
    auto action = peel(&args);
    if(action is null || action == "build")
    {
        return dmdBuild(contractor, contractFile, contract);
    }
    if(action == "clean")
    {
        return dmdClean(contractor, contractFile, contract);
    }

    writefln("dmd action \"%s\" not implemented", action);
    return ContractorResult.errorStop;
}

bool isAbsolute(T)(T path)
{
    import std.path : isAbsolute;
    if (isAbsolute(path))
        return true; // is absolute
    return false; // not absolute
}

auto resolvePath(T,U)(T path, U base)
{
    if (isAbsolute(path))
        return path;
    return buildPath(base, path);
}

struct DmdContractFields
{
    string targetName;
    EnumValue targetType;
    string outputDirectoryValue;
    string outputDirectory;
    string objectDirectory;
    string targetFile;
    bool useLibFlag;

    bool includeImports;

    this(BidmakeFile contractFile, Contract contract)
    {
        this.targetName = contract.lookupField!(PrimitiveTypeName.filename)("targetName");
        this.targetType = contract.lookupEnumField("targetType", Yes.required);
        this.outputDirectoryValue = contract.lookupField!(PrimitiveTypeName.dirpath)("outputDirectory");
        this.outputDirectory = this.outputDirectoryValue.resolvePath(contractFile.dir);
        this.objectDirectory = contract.lookupField!(PrimitiveTypeName.dirpath)("objectDirectory");
        this.targetFile = buildPath(outputDirectory, targetName);
        if (targetType.name == "exe")
        {
            version(Windows)
                this.targetFile = this.targetFile ~ ".exe";
        }
        else if (targetType.name == "staticLibrary")
        {
            useLibFlag = true;
            version(Windows)
                this.targetFile = this.targetFile ~ ".lib";
            else
                this.targetFile = this.targetFile ~ ".a";
        }
        else if (targetType.name == "dynamicLibrary")
        {
            useLibFlag = true;
            version(Windows)
                this.targetFile = this.targetFile ~ ".dll";
            else
                this.targetFile = this.targetFile ~ ".so";
        }
        else if (targetType.name == "objectFile")
        {
            version(Windows)
                this.targetFile = this.targetFile ~ ".obj";
            else
                this.targetFile = this.targetFile ~ ".o";
        }
        else assert(0, "unhandled target type: " ~ targetType.name);
        this.includeImports = contract.lookupField!(PrimitiveTypeName.bool_)("includeImports");
    }
    Flag!"valid" verify() const
    {
        auto result = Yes.valid;
        if (includeImports)
        {
            if (objectDirectory is null)
            {
                writefln("Error: 'objectDirectory' must be set if you want to 'includeImports'." ~
                         " This is so there is a place to store the json file which contains the module file dependnecies.");
                result = No.valid;
            }
        }
        return result;
    }
}

// TODO: need a way to make sure that the same contractor
//       is used for the clean as was used for the build
ContractorResult dmdClean(Contractor contractor, BidmakeFile contractFile, Contract contract)
{
    auto fields = DmdContractFields(contractFile, contract);
    if (!fields.verify())
        return ContractorResult.errorStop;

    // TODO: clean obj files


    // TODO: clean files in object directory

    if(exists(fields.targetFile))
    {
        writefln("removing %s", fields.targetFile.formatQuotedIfSpaces);
        remove(fields.targetFile);
    }
    writefln("WARNING: dmd clean not fully implemented");
    return ContractorResult.errorContinue;
}

auto toArray(string code, T, Args...)(T range, Args args)
{
    auto array = new ElementType!T[range.length];
    size_t index = 0;
    for(; !range.empty; range.popFront())
    {
        mixin("array[index] = " ~ code ~ ";");
        index++;
    }
    assert(index == array.length);
    return array;
}

ContractorResult dmdBuild(Contractor contractor, BidmakeFile contractFile, Contract contract)
{
    auto fields = DmdContractFields(contractFile, contract);
    if (!fields.verify())
        return ContractorResult.errorStop;

    auto targetTime = timeLastModified(fields.targetFile, SysTime.max);
    auto contractSourceList = contract.lookupListField!(PrimitiveTypeName.filepath)("source");

    auto sourceFiles = contractSourceList.range.toArray!q{buildPath(args[0].dir, range.front)}(contractFile);

    string includeImportsJsonFile = buildPath(fields.objectDirectory,
        fields.outputDirectoryValue.replace("/", "_") ~ "_" ~ fields.targetName ~ ".json");

    if(targetTime == SysTime.max)
    {
        writefln("[DEBUG] binary \"%s\" does not exist", fields.targetFile);
    }
    else
    {
        string[] allSourceFiles;
        if (!fields.includeImports)
        {
            allSourceFiles = sourceFiles;
        }
        else
        {
            if (!exists(includeImportsJsonFile))
            {
                writefln("json file \"%s\" does not exist, cannot check all dependencies", includeImportsJsonFile);
                goto COMPILE;
            }
            allSourceFiles = getModuleFiles(includeImportsJsonFile);
        }

        foreach(source; allSourceFiles)
        {
            auto sourceTime = timeLastModified(source, SysTime.max);
            if(sourceTime == SysTime.max)
            {
                writefln("Error: cannot build \"%s\" because source file \"%s\" does not exist", fields.targetFile, source);
                return ContractorResult.errorStop;
            }
            if(sourceTime > targetTime)
            {
                writefln("[DEBUG] source file \"%s\" (time %s) is newer than executable \"%s\" (time %s)",
                         source, sourceTime, fields.targetFile, targetTime);
                goto COMPILE;
            }
        }

        writefln("binary \"%s\" is up-to-date", fields.targetFile);
        return ContractorResult.success;
    }

  COMPILE:

    auto command = appender!(char[]);

    //writefln("dmdExecute:\n%s", contract.formatPretty);

    //
    // TODO: need code that finds the correct dmd executable (look to dbuild for an example)
    //
    //command.putf("%s", instance.fullPathExe.formatQuotedIfSpaces());
    command.put("dmd");

    if (fields.useLibFlag)
    {
        command.put(" -lib");
    }

    command.putf(" %s", formatQuotedIfSpaces("-of", fields.targetFile));
    if(fields.objectDirectory !is null)
    {
        command.putf(" %s", formatQuotedIfSpaces("-od", fields.objectDirectory));
    }
    /*
    final switch(contract.compileMode)
    {
        case CompileMode.default_:
        command.put(" -g -debug");
        break;
        case CompileMode.debug_:
        command.put(" -g -debug");
        break;
        case CompileMode.release:
        command.put(" -release");
        break;
    }
    */
    if (fields.includeImports)
    {
        command.put(" -i");
        command.putf(" %s", formatQuotedIfSpaces("-Xf=", includeImportsJsonFile));
        command.putf(" -Xi=semantics");
    }
    foreach(includePath; contract.lookupListField!(PrimitiveTypeName.dirpath)("includePath").range)
    {
        command.putf(" %s", formatQuotedIfSpaces("-I", includePath));
    }
    foreach(library; contract.lookupListField!(PrimitiveTypeName.filepath)("library").range)
    {
        command.putf(" %s", formatQuotedIfSpaces(library));
    }
    foreach(source; sourceFiles)
    {
        command.putf(" %s", source.formatQuotedIfSpaces);
    }

    if(tryRun(cast(string)command.data))
    {
        return ContractorResult.errorStop;
    }
    return ContractorResult.success;
}


bool asBool(ref const JSONValue val)
{
    import std.conv : to;
    import std.json : JSON_TYPE;
    if (val.type == JSON_TYPE.TRUE)
        return true;
    if (val.type == JSON_TYPE.FALSE)
        return false;
    assert(0, "expected json bool value, but is " ~ val.type.to!string);
}
string getOptionalString(const JSONValue[string] obj, string name)
{
    import std.conv : to;
    import std.json : JSON_TYPE;
    auto val = obj.get(name, JSONValue.init);
    if (val.isNull)
        return null;
    assert(val.type == JSON_TYPE.STRING,
       "expected json value to be string but is " ~ val.type.to!string);
    return val.str;
}

string[] getModuleFiles(string jsonFilename)
{
    auto jsonText = readText(jsonFilename);
    auto json = parseJSON(jsonText);
    auto modules = json["semantics"]["modules"].array;
    string[] sources = [];

    foreach (modValue; modules)
    {
        const mod = modValue.object;
        const isRoot = mod["isRoot"].asBool;
        const name = mod.getOptionalString("name");
        if (isRoot || name == "object")
        {
            sources ~= mod["file"].str;
        }
    }

    return sources;
}

//
// Git
//
ContractorResult gitExecute(Contractor contractor, BidmakeFile contractFile, Contract contract, string[] args)
{
    auto action = peel(&args);
    if(action is null)
    {
        // do nothing by default
        return ContractorResult.success;
    }
    /*
    if(action == "download")
    {
        return gitDownload(contractor, contractFile, contract);
    }
    */
    if(action == "clean")
    {
        return gitClean(contractor, contractFile, contract);
    }

    writefln("git action \"%s\" not implemented", action);
    return ContractorResult.errorStop;
}
struct GitContractFields
{
    string url;
    string commit;
    string dir;
    this(BidmakeFile contractFile, Contract contract)
    {
        this.url = contract.lookupField!(PrimitiveTypeName.string_)("url");
        if(url.length == 0)
        {
            writefln("Error: no 'url' was specified");
            throw quit;
        }
        this.commit = contract.lookupField!(PrimitiveTypeName.string_)("commit");
        this.dir = contract.lookupField!(PrimitiveTypeName.dirpath)("dir");
        assert(this.dir.length > 0, "git dir is empty");
    }
}

/*
ContractorResult gitDownload(Contractor contractor, BidmakeFile contractFile, Contract contract)
{
    auto fields = GitContractFields(contractFile, contract);
    if(!exists(fields.dir))
    {
        writefln("git repo \"%s\" does not exist", fields.dir);

        auto command = appender!(char[]);
        command.put("git clone");
        if(fields.commit.length > 0)
        {
            command.putf(" -b %s", fields.commit.formatQuotedIfSpaces);
        }
        command.put(" ");
        command.put(fields.url);
        command.putf(" %s", fields.dir.formatQuotedIfSpaces);
        run(command.data);
    }
    else if(fields.commit.length > 0)
    {
        // make sure the correct commit is checked out
        auto command = appender!(char[]);
        command.put("git");
        command.putf(" -C %s", fields.dir.formatQuotedIfSpaces);
        command.putf(" checkout %s", fields.commit.formatQuotedIfSpaces);
        run(command.data);
    }
    else
    {
        writefln("git repo \"%s\" already exists", fields.dir);
    }
    return ContractorResult.success;
}
*/
ContractorResult gitClean(Contractor contractor, BidmakeFile contractFile, Contract contract)
{
    auto fields = GitContractFields(contractFile, contract);
    if(exists(fields.dir))
    {
        writefln("TODO: remove directory %s", fields.dir.formatQuotedIfSpaces);
    }
    return ContractorResult.errorContinue;
}