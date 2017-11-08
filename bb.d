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

void loadRepo()
{
    static bool repoLoaded = false;

    assert(!repoLoaded, "code bug: repo is already loaded");
    repoLoaded = true;

    writefln("[DEBUG] loading repo at \"%s\"", repoPath);
    if(!exists(repoPath))
    {
        writefln("[DEBUG] repo has not been created");
        return;
    }
    if(!isDir(repoPath))
    {
        writefln("Error: repo path \"%s\" is not a directory", repoPath);
        throw quit;
    }
    auto repoConfigFilesBuilder = appender!(ConfigFile[]);
    foreach(entry; dirEntries(repoPath, SpanMode.shallow))
    {
        if(!entry.isFile)
        {
            writefln("Error: repo contains non-file \"%s\"", entry.name);
            throw quit;
        }
        writefln("[DEBUG] loading \"%s\"", entry.name);
        repoConfigFilesBuilder.put(ConfigFile.load(entry.name));
    }
    repoConfigFiles = repoConfigFilesBuilder.data;
    writefln("[DEBUG] loaded %s file(s) from repo", repoConfigFiles.length);
}
void createRepo()
{
    if(!exists(repoPath))
    {
        mkdir(repoPath);
    }
}

void build(string[] files)
{
    foreach(file; files)
    {
        if(!exists(file))
        {
            writefln("Error: file \"%s\" does not exist", file);
            throw quit;
        }

        auto configFile = ConfigFile.load(file);

        {
            auto depTree = DependencyTree(configFile.config.BuildStepList, configFile.config.BuildContractList);

            currentConfigFile = &configFile;

            currentDepTree = &depTree;
            scope(exit)
            {
                currentDepTree = null;
                currentConfigFile = null;
            }

            // Build Dependency Tree
            foreach(ref step; configFile.config.BuildStepList)
            {
                dependencyScan(&depTree, step);
            }
            foreach(ref contract; configFile.config.BuildContractList)
            {
                dependencyScan(&depTree, contract);
            }

            /*
            foreach(dep; depTree.dependencies)
            {
                writeln(dep);
            }
            */

          BUILD_LOOP:
            while(1)
            {
                size_t skipCount = 0;
              NODE_LOOP:
                foreach(ref node; depTree.dependencies)
                {
                    if(!node.built)
                    {
                        foreach(dep; node.dependencies)
                        {
                            if(!dep.built)
                            {
                                skipCount++;
                                continue NODE_LOOP;
                            }
                        }
                        final switch(node.contractOrStep.kind)
                        {
                            case BuildKind.contract:
                                node.Output = buildContract(*node.contractOrStep.asContract);
                                break;
                            case BuildKind.step:
                                node.Output = buildStep(*node.contractOrStep.asStep);
                                break;
                        }
                        node.built = true;
                        continue BUILD_LOOP;
                    }
                }

                if(skipCount == 0)
                {
                    break;
                }

                writefln("Error: could not build everything, maybe there is some circular dependencies?");
                throw quit;
            }
        }
    }
}

struct DependencyTree
{
    DependencyTreeNode[] dependencies;
    this(BuildStep[] steps, BuildContract[] contracts)
    {
        this.dependencies = new DependencyTreeNode[steps.length + contracts.length];
        foreach(i; 0..steps.length)
        {
            dependencies[i] = DependencyTreeNode(BuildContractOrStep(&steps[i]));
        }
        foreach(i; 0..contracts.length)
        {
            dependencies[steps.length + i] = DependencyTreeNode(BuildContractOrStep(&contracts[i]));
        }
    }
    DependencyTreeNode* get(BuildContractOrStep contractOrStep)
    {
        foreach(i; 0..dependencies.length)
        {
            if(dependencies[i].contractOrStep.ptr is contractOrStep.ptr)
            {
                return &dependencies[i];
            }
        }
        assert(0, "dependency tree did not contain " ~ contractOrStep.kind.to!string ~ " named " ~ contractOrStep.name);
    }
}
enum BuildKind { contract, step }
struct DependencyTreeNode
{
    BuildContractOrStep contractOrStep;

    bool built;
    bidmake.standard.Output Output;

    DependencyTreeNode*[] dependencies;
    void addDependency(DependencyTreeNode* dependency)
    {
        assert(&this != dependency);
        foreach(existing; dependencies)
        {
            if(existing is dependency)
            {
                return;
            }
        }
        dependencies ~= dependency;
    }
}

// Note: keep this in sync with the Name grammar rule
auto variableReferenceRegex = ctRegex!(`\$\([^\)]*\)`);

void dependencyScan(DependencyTree* depTree, ref const(BuildStep) step)
{
    // Scan places where there could be dependencies
    foreach(value; chain(
        map!(e => e.Name)(step.ExecuteList),
        joiner(map!(s => s.FileList.unconst)(step.SourceList)),
        step.DependsOnList))
    {
        foreach(match; matchAll(value, variableReferenceRegex))
        {
            assert(match.hit[0..2] == "$(" && match.hit[$-1] == ')');
            auto reference = match.hit[2..$-1];
            dependencyScan(depTree, BuildContractOrStep(&step), reference);
        }
    }
}
void dependencyScan(DependencyTree* depTree, ref const(BuildContract) contract)
{
    // Scan places where there could be dependencies
    foreach(value; chain(
        contract.DependsOnList,
        contract.DLanguageOptions.StringImportPathList,
        contract.LibraryList,
        joiner(map!(s => s.FileList.unconst)(contract.SourceList))))
    {
        foreach(match; matchAll(value, variableReferenceRegex))
        {
            assert(match.hit[0..2] == "$(" && match.hit[$-1] == ')');
            auto reference = match.hit[2..$-1];
            dependencyScan(depTree, BuildContractOrStep(&contract), reference);
        }
    }
}

enum outputPostfix = ".Output";
enum outputPathPostfix = ".OutputPath";

void dependencyScan(DependencyTree* depTree, BuildContractOrStep contractOrStep, string qualifiedName)
{
    // Right now, a BuildContract X is dependent on BuildContract Y if and
    // only if X uses $(Y.Output).
    if(qualifiedName.endsWith(outputPostfix))
    {
        auto name = qualifiedName[0..$-outputPostfix.length];
        auto dependency = findBuildContractOrStep(name);
        if(dependency.ptr is null)
        {
            writefln("Error: undefined reference to \"%s\"", qualifiedName);
            throw quit;
        }
        if(dependency.ptr is &contractOrStep)
        {
            writefln("Error: %s '%s' has a dependency on it's own Output!", contractOrStep.kind, contractOrStep.name);
            throw quit;
        }
        depTree.get(contractOrStep).addDependency(depTree.get(dependency));
    }
}
bool canBuild(ref const(BuildContractor) contractor, string outputType, const(Source)[] sources)
{
    if(!contractor.SupportedOutputTypeList.canFind(outputType))
    {
        return false;
    }

    foreach(source; sources)
    {
        if(!contractor.SupportedLanguageList.canFind(source.Language))
        {
            return false;
        }
    }

    return true;
}

void appendCommandLineArgument(T, U...)(T outputRange, U argParts)
{
    if(outputRange.data.length > 0)
    {
        outputRange.put(" ");
    }

    // Check if the argument needs quotes
    bool useQuotes = false;
    foreach(part; argParts)
    {
        if(part.canFind(" "))
        {
            useQuotes = true;
        }
    }

    if(useQuotes)
    {
        outputRange.put("\"");
    }
    foreach(part; argParts)
    {
        outputRange.put(part);
    }
    if(useQuotes)
    {
        outputRange.put("\"");
    }
}

string resolveConditionExpression(T)(ref const(T) dataStructure, string expr)
{
    auto peeled = peelQualifiedName(expr);
    if(peeled.rest.length > 0)
    {
        if(peeled.nextName == "Contract")
        {
            return getOneItem!T(dataStructure, peeled.rest);
        }
        else
        {
            writefln("unknown variable \"%s\"", expr);
            throw quit;
        }
    }
    else
    {
        return expr;
    }
}
bool conditionFails(T)(ref const(T) dataStructure, EqualCondition equalCondition)
{
    auto leftResolved = resolveReferences(equalCondition.Left);
        //resolveConditionExpression!T(dataStructure, equalCondition.Left);
    auto rightResolved = resolveReferences(equalCondition.Right);
        //resolveConditionExpression!T(dataStructure, equalCondition.Right);
    return leftResolved != rightResolved;
}

string transform(string listItem, ref const(CommandLine) commandLine)
{
    string transformed = listItem;
    if(commandLine.StripPath)
    {
        transformed = baseName(transformed);
    }
    if(commandLine.ReplaceExtension)
    {
        transformed = setExtension(transformed, commandLine.ReplaceExtension);
    }
    return transformed;
}

void addCommandLine(T,Range)(Range outputRange, ref const(T) dataStructure, ref const(CommandLine) commandLine)
{
    if(commandLine.ExpandList && commandLine.AddArgument)
    {
        writefln("A CommandLine block cannot have both ExpandList and AddArgument");
        throw quit;
    }

    auto resolvedPreArgument = resolveReferences(commandLine.PreArgument);
    auto resolvedPostArgument = resolveReferences(commandLine.PostArgument);
    auto resolvedPrefix = resolveReferences(commandLine.Prefix);
    auto resolvedPostfix = resolveReferences(commandLine.Postfix);

    if(commandLine.ExpandList)
    {
        //writefln("list %s", commandLine.ExpandList);
        auto listElements = appender!(string[]);
        {
            auto peeled = peelQualifiedName(commandLine.ExpandList);
            if(peeled.nextName == "Contract")
            {
                getListItems!T(dataStructure, peeled.rest, listElements);
            }
            else
            {
                writefln("unknown variable \"%s\" in \"ExpandList %s\"", peeled.nextName, commandLine.ExpandList);
                throw quit;
            }
        }
        //writefln("%s elements", listElements.data.length);

        if(commandLine.Join)
        {
            writefln("CommandLine.Join not implemented");
            throw quit;
        }
        foreach(listElement; listElements.data)
        {
            foreach(ref equalCondition; commandLine.EqualConditionList)
            {
                if(conditionFails(dataStructure, equalCondition))
                {
                    continue;
                }
            }
            if(resolvedPreArgument)
            {
                outputRange.appendCommandLineArgument(resolvedPreArgument);
            }
            outputRange.appendCommandLineArgument(resolvedPrefix, resolveReferences(listElement).transform(commandLine), resolvedPostfix);
            if(resolvedPostArgument)
            {
                outputRange.appendCommandLineArgument(resolvedPostArgument);
            }
        }
    }
    else if(commandLine.AddArgument)
    {
        foreach(ref equalCondition; commandLine.EqualConditionList)
        {
            if(conditionFails(dataStructure, equalCondition))
            {
                return;
            }
        }
        if(resolvedPreArgument)
        {
            outputRange.appendCommandLineArgument(resolvedPreArgument);
        }
        outputRange.appendCommandLineArgument(resolvedPrefix, resolveReferences(commandLine.AddArgument).transform(commandLine), resolvedPostfix);
        if(resolvedPostArgument)
        {
            outputRange.appendCommandLineArgument(resolvedPostArgument);
        }
    }
    else
    {
        writefln("don't know how to expand this command line: %s", commandLine);
        throw quit;
    }
}

auto tryRunShell(const(char)[] command)
{
    writeln(command);
    return wait(spawnShell(command));
}
void runShell(const(char)[] command)
{
    auto exitCode = tryRunShell(command);
    if(exitCode)
    {
        writefln("Error: build command exited with code %s", exitCode);
        throw quit;
    }
}

void performExecute(T)(ref const(T) dataStructure, const(Execute) execute)
{
    // Check conditions
    foreach(ref equalCondition; execute.EqualConditionList)
    {
        if(conditionFails(dataStructure, equalCondition))
        {
            return;
        }
    }

    auto commandLineAppender = appender!(char[])();

    commandLineAppender.appendCommandLineArgument(resolveReferences(execute.Name));
    foreach(ref commandLine; execute.CommandLineList)
    {
        addCommandLine!(T,Appender!(char[]))(commandLineAppender, dataStructure, commandLine);
    }
    runShell(commandLineAppender.data);
}

void build(ref const(BuildContractor) contractor, ref const(BuildContract) contract)
{
    foreach(ref executeProps; contractor.ExecuteList)
    {
        performExecute(contract, executeProps);
    }
}

struct BuildContractOrStep
{
    const(void)* ptr;
    BuildKind kind;
    this(const(BuildContract)* contract)
    {
        this.kind = BuildKind.contract;
        this.ptr = cast(const(void)*)contract;
    }
    this(const(BuildStep)* step)
    {
        this.kind = BuildKind.step;
        this.ptr = cast(const(void)*)step;
    }
    @property auto asContract() in { assert(kind == BuildKind.contract); } body
    {
        return cast(const(BuildContract)*)ptr;
    }
    @property auto asStep() in { assert(kind == BuildKind.step); } body
    {
        return cast(const(BuildStep)*)ptr;
    }
    @property string name()
    {
        final switch(kind)
        {
            case BuildKind.contract:
                return asContract.Name;
            case BuildKind.step:
                return asStep.Name;
        }
    }
}

BuildContractOrStep findBuildContractOrStep(string name)
{
    foreach(configFile; allConfigFiles)
    {
        foreach(ref contract; configFile.config.BuildContractList)
        {
            if(contract.Name == name)
            {
                return BuildContractOrStep(&contract);
            }
        }
        foreach(ref step; configFile.config.BuildStepList)
        {
            if(step.Name == name)
            {
                return BuildContractOrStep(&step);
            }
        }
    }
    return BuildContractOrStep();
}

auto findBuildContractors(string targetType, const(Source)[] sources)
{
    auto contractors = appender!(const(BuildContractor)[])();
    foreach(configFile; allConfigFiles)
    {
        foreach(contractor; configFile.config.BuildContractorList)
        {
            if(contractor.canBuild(targetType, sources))
            {
                contractors.put(contractor);
            }
        }
    }
    return contractors.data;
}
+/
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

Output buildStep(ref const(BuildStep) step)
{
    foreach(ref executeProps; step.ExecuteList)
    {
        performExecute(step, executeProps);
    }
    return step.Output.unconst;
}

Output buildContract(ref const(BuildContract) contract)
{
    assert(currentContract is null);
    currentContract = &contract;
    scope(exit) currentContract = null;

    string outputExtension;
    if(contract.OutputType == "Executable")
    {
        version(Windows)
        {
            outputExtension = ".exe";
        }
        else
        {
            outputExtension = null;
        }
    }
    else if(contract.OutputType == "StaticLibrary")
    {
        outputExtension = ".lib";
    }
    else if(contract.OutputType == "ObjectFile")
    {
        version(Windows)
        {
            outputExtension = ".obj";
        }
        else
        {
            outputExtension = ".o";
        }
    }
    else
    {
        throw new Exception(format("Error: BuildContract has unhandled TargetType \"%s\"", contract.OutputType));
    }

    string outputName = contract.OutputName;
    if(outputName.length == 0)
    {
        outputName = contract.Name;
        if(outputName.length == 0)
        {
            writefln("Error: there is no OutputName and the BuildContract does not have a name");
            throw quit;
        }
    }
    writefln("[bidmake] Building %s", outputName);
    string exeName = outputName ~ outputExtension;

    if(std.file.exists(exeName))
    {
        writefln("[bidmake] Removing existing executable \"%s\"", exeName);
        std.file.remove(exeName);
    }

    if(contract.SourceList.length == 0)
    {
        writefln("Error: BuildContract is missing Source properties");
        throw quit;
    }

    auto contractors = findBuildContractors("Executable", contract.SourceList);
    if(contractors.length == 0)
    {
        writefln("Did not find any Executable build contractors for %s", outputName);
        throw quit;
    }

    writefln("[bidmake] Found %s build contractor(s) for %s", contractors.length, outputName);
    foreach(i, contractor; contractors)
    {
        writefln("[bidmake]   %s. %s", i, contractor.Name);
    }
    string prompt;
    if(contractors.length == 1)
    {
        prompt = "Enter 0 to confirm build with this contractor: ";
    }
    else
    {
        prompt = format("Select build contractor[0-%s]: ", contractors.length - 1);
    }
    auto contractorIndex = promptNumber(prompt, contractors.length - 1);
    contractors[contractorIndex].build(contract);

    if(!std.file.exists(exeName))
    {
        writefln("Error: invoked the build contractor but it did not build the executable \"%s\"", exeName);
        throw quit;
    }

    Output returnValue;
    returnValue.ExecutableList = [exeName];
    return returnValue;
}