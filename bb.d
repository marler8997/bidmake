#!/usr/bin/env rund
//!importPath ../mored

import std.stdio;
import std.path : dirName, buildPath, baseName;
import std.file : exists, isDir, mkdir, dirEntries, SpanMode, timeLastModified;
import std.path : baseName, setExtension, relativePath, absolutePath, buildNormalizedPath;
import std.format : format;
import std.string : stripRight, startsWith, endsWith;
import std.typecons : Flag, Yes, No, Rebindable;
import std.algorithm : canFind, map, joiner;
import std.range : chain, only;
import std.regex : ctRegex, matchAll;
import std.array : Appender, appender, replace;
import std.conv : to, ConvException;
import std.process : spawnShell, wait;
import std.digest.sha : sha1Of;

static import std.file;

import util;
import bidmake.analyzer;

void usage()
{
    writeln("Usage:");
    writeln();
    writeln("The following will read all *.bidmake files (maybe bidmake.* in the future) and run the given command.");
    writeln();
    writeln("bb [<command> <args>...]");
    writeln();
    writeln("The rest are pre-defined commands that perform various operations:");
    writeln();
    writeln("bb install [copy|redirect] <files>...");
}
int main(string[] args)
{
    // setup the global repo path
    // TODO: use thisExePath instead of __FILE_FULL_PATH__ when bb is precompiled (not being run by rdmd).
    globalRepoPath = buildPath(__FILE_FULL_PATH__.dirName, "bidmakerepo");
    if(!exists(globalRepoPath))
    {
        writefln("[DEBUG] creating global repo \"%s\"", globalRepoPath);
        mkdir(globalRepoPath);
    }

    args = args[1..$];
    {
        int newArgsLength = 0;
        for(size_t i = 0; i < args.length; i++)
        {
            auto arg = args[i];
            if(arg.length == 0 || arg[0] != '-')
            {
                args[newArgsLength++] = arg;
            }
            else if(arg == "-h" || arg == "-help" || arg == "--help")
            {
                usage();
                return 1;
            }
            else
            {
                writefln("Error: unknown option \"%s\"", arg);
                return 1;
            }
        }
        args = args[0..newArgsLength];
    }

    string command;
    if(args.length > 0)
    {
        command = args[0];
    }

    try
    {
        if(command == "install")
        {
            args = args[1..$];
            if(args.length == 0)
            {
                writefln("Usage: bb install [copy|redirect] <file>...");
                return 1;
            }
            auto installOptionString = args[0];
            args = args[1..$];
            InstallOption installOption;
            if(installOptionString == "copy")
            {
                installOption = InstallOption.copy;
            }
            else if(installOptionString == "redirect")
            {
                installOption = InstallOption.redirect;
            }
            else
            {
                writefln("Error: unknown install option \"%s\", expected 'copy' or 'redirect'", installOptionString);
                return 1;
            }
            if(args.length == 0)
            {
                writefln("No files given to install");
                return 1;
            }
            install(installOption, args);
        }
        else
        {
            auto bidmakeFiles = appender!(BidmakeFile[])();
            readBidmakeFiles(bidmakeFiles, null);
            if(bidmakeFiles.data.length == 0)
            {
                writefln("no bidmake files in this directory");
                return 1;
            }
            return defaultRun(bidmakeFiles.data, args);
        }

        return 0;
    }
    catch(QuitException)
    {
        return 1;
    }
}

enum InstallOption
{
    copy, redirect,
}
void install(InstallOption installOption, string[] filesToInstall)
{
    foreach(fileToInstall; filesToInstall)
    {
        if(!exists(fileToInstall))
        {
            writefln("Error: file \"%s\" does not exist", fileToInstall);
            throw quit;
        }

        // load and parse the file (note: could also analyze it)
        auto bidmakeFile = loadBidmakeFile(fileToInstall, Yes.parse);

        string installContents;
        if(installOption != InstallOption.redirect)
        {
            installContents = bidmakeFile.contents;
        }
        else
        {
            auto fileToInstallAbsolute = buildNormalizedPath(absolutePath(fileToInstall));
            auto redirectPath = relativePath(fileToInstallAbsolute, globalRepoPath).buildNormalizedPath();
            version(Windows)
            {
                redirectPath = redirectPath.replace("\\", "/");
            }
            installContents = format("redirect %s;\n", redirectPath.formatQuotedIfSpaces);
        }

        // Check if the file has already been installed
        auto installedFilePath = buildPath(globalRepoPath, baseName(fileToInstall));

        bool installThisFile;
        if(!exists(installedFilePath))
        {
            installThisFile = true;
        }
        else
        {
            auto newHash = sha1Of(installContents);

            auto currentConfig = loadBidmakeFile(installedFilePath, No.parse);
            auto currentHash = sha1Of(currentConfig.contents);

            if(newHash == currentHash)
            {
                writefln("already installed \"%s\"", installedFilePath);
                installThisFile = false;
            }
            else
            {
                auto existingModifyTime = timeLastModified(installedFilePath);
                auto installingModifyTime = timeLastModified(fileToInstall);
                string existingNote = "";
                string installingNote = "";
                if(installingModifyTime > existingModifyTime)
                {
                    existingNote   = "       ";
                    installingNote = "*newer ";
                }
                else if(installingModifyTime < existingModifyTime)
                {
                    existingNote   = "*newer ";
                    installingNote = "       ";
                }
                else
                {
                    existingNote   = "*sameage ";
                    installingNote = "*sameage ";
                }
                writefln("already exists \"%s\"", installedFilePath);
                writefln("  %sexisting   (modified at %s) %s", existingNote, existingModifyTime, installedFilePath);
                writefln("  %sinstalling (modified at %s) %s", installingNote, installingModifyTime, fileToInstall);
                installThisFile = prompYesNo("overwrite?[y/n] ");
            }
        }

        if(installThisFile)
        {
            if(installOption == InstallOption.copy)
            {
                std.file.copy(fileToInstall, installedFilePath);
            }
            else
            {
                auto file = File(installedFilePath, "w");
                scope(exit) file.close();
                file.rawWrite(installContents);
            }
            writefln("installed \"%s\"", installedFilePath);
        }
    }
}


void readBidmakeFiles(Appender!(BidmakeFile[]) outFiles, string[] files)
{
    if(files.length == 0)
    {
        foreach(entry; dirEntries(".", "*.bidmake", SpanMode.shallow))
        {
            outFiles.put(loadBidmakeFile(entry.name, Yes.parse));
        }
    }
    else
    {
        foreach(file; files)
        {
            /*
            todo: check if the same file is given more than once
            foreach(existing; globalBidmakeFiles.data.length)
            {
                if(filename == existing.filename)
                {
                    writefln("Error: file \"%s\" is being loaded more than once", filename);
                    throw quit;
                }
            }
            */
            outFiles.put(loadBidmakeFile(file, Yes.parse));
        }
    }
}
int defaultRun(BidmakeFile[] bidmakeFiles, string[] args)
{
    bool errorOccurred = false;
    foreach(bidmakeFile; bidmakeFiles)
    {
        final switch(defaultRunFile(bidmakeFile, args))
        {
            case ContractorResult.success:
                break;
            case ContractorResult.errorStop:
                return 1; // error
            case ContractorResult.errorContinue:
                errorOccurred = true;
                break;
        }
    }
    return errorOccurred ? 1 : 0;
}
ContractorResult defaultRunFile(BidmakeFile bidmakeFile, string[] args)
{
    bidmakeFile = analyze(bidmakeFile);

    auto result = ContractorResult.success;
    foreach(contract; bidmakeFile.contracts)
    {
        final switch(defaultRunContract(bidmakeFile, contract, args))
        {
            case ContractorResult.success:
                break;
            case ContractorResult.errorStop:
                return ContractorResult.errorStop;
            case ContractorResult.errorContinue:
                result = ContractorResult.errorContinue;
                break;
        }
    }
    foreach(include; bidmakeFile.includes)
    {
        final switch(defaultRunFile(include, args))
        {
            case ContractorResult.success:
                break;
            case ContractorResult.errorStop:
                return ContractorResult.errorStop;
            case ContractorResult.errorContinue:
                result = ContractorResult.errorContinue;
                break;
        }
    }
    return result;
}
ContractorResult defaultRunContract(BidmakeFile bidmakeFile, Contract contract, string[] args)
{
    string action = (args.length == 0) ? null : args[0];

    auto contractors = appender!(Contractor[]);
    bidmakeFile.findContractors(contractors, contract, action);

    if(contractors.data.length == 0)
    {
        writefln("Error: no contractor found to execute the \"%s\" action on these contracts",
            (action is null) ? "<default>" : action);
        return ContractorResult.errorStop;
    }

    // execute the contractors in order
    auto result = ContractorResult.success;
    foreach (ref contractor; contractors.data)
    {
        final switch (contractor.execute(bidmakeFile, contract, args))
        {
            case ContractorResult.success:
                break;
            case ContractorResult.errorStop:
                return ContractorResult.errorStop;
            case ContractorResult.errorContinue:
                result = ContractorResult.errorContinue;
                break;
        }
    }
    return result;
    /*
    if(contractors.data.length > 1)
    {
        writefln("Error: there are multiple contractors to execute this action, this is not currently supported");
        return ContractorResult.errorStop;
    }
    return contractors.data[0].execute(bidmakeFile, contract, args);
    */
}

auto promptNumber(string prompt, size_t max)
{
    for(;;)
    {
        write(prompt);
        stdout.flush();
        auto input = stdin.readln().stripRight();
        if(input == "q")
        {
            throw quit;
        }
        try
        {
            auto result = input.to!size_t();
            if(result > max)
            {
                continue;
            }
            return result;
        }
        catch(ConvException)
        {
        }
    }
}
auto prompYesNo(string prompt)
{
    for(;;)
    {
        write(prompt);
        stdout.flush();
        auto input = stdin.readln().stripRight();
        if(input == "y")
        {
            return true;
        }
        else if(input == "n")
        {
            return false;
        }
    }
}