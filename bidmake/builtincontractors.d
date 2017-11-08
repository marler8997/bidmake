module bidmake.builtincontractors;

import std.stdio;
import std.file  : exists, remove, timeLastModified;
import std.path  : buildPath;
import std.array : appender;
import std.range : ElementType;
import std.datetime : SysTime;

import util : peel, tryRun, putf, formatQuotedIfSpaces;
import bidmake.analyzer;

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

struct ContractFields
{
    string targetName;
    string outputDirectory;
    string targetFile;

    string objectDirectory;
    this(BidmakeFile contractFile, Contract contract)
    {
        this.targetName = contract.lookupField!(PrimitiveTypeName.filename)("targetName");
        this.outputDirectory = buildPath(contractFile.dir, contract.lookupField!(PrimitiveTypeName.dirpath)("outputDirectory"));
        this.targetFile = buildPath(outputDirectory, targetName);
        version(Windows)
        {
            this.targetFile = this.targetFile ~ ".exe";
        }
        this.objectDirectory = contract.lookupField!(PrimitiveTypeName.dirpath)("objectDirectory");
    }
}

// TODO: need a way to make sure that the same contractor
//       is used for the clean as was used for the build
ContractorResult dmdClean(Contractor contractor, BidmakeFile contractFile, Contract contract)
{
    auto fields = ContractFields(contractFile, contract);

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
    auto fields = ContractFields(contractFile, contract);
    auto targetTime = timeLastModified(fields.targetFile, SysTime.max);
    auto contractSourceList = contract.lookupListField!(PrimitiveTypeName.filepath)("source");

    auto sourceFiles = contractSourceList.range.toArray!q{buildPath(args[0].dir, range.front)}(contractFile);


    if(targetTime == SysTime.max)
    {
        writefln("[DEBUG] binary \"%s\" does not exist", fields.targetFile);
    }
    else
    {
        foreach(source; sourceFiles)
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