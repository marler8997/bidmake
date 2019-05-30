module bidmake.builtinfunctions;

import std.stdio : writefln;
import std.path  : baseName, dirName, absolutePath, buildNormalizedPath;
import std.file  : dirEntries, SpanMode;
import std.conv  : to;
import std.array : appender;
import std.typecons : Flag, Yes, No;

import more.format : StringSink;
import more.esb : Expression, ExpressionType, Statement, StatementRangeReference;
import more.repos : insideGitRepo;

import util : quit, defaultPathSeparatorChar, isPathSeparator;
import bidmake.analyzer;

// returns error string on error
ErrorString interpretCall(IScope scope_, TypedValue* outTypedValue, const(Type) targetType, Expression call)
    in { assert(call.type == ExpressionType.functionCall); } body
{
    auto functionName = call.functionName();
    //writefln("[DEBUG] Calling function '%s'", functionName);
    if(functionName == "basename")
    {
        return callBasename(scope_, outTypedValue, call);
    }
    else if(functionName == "parentDir")
    {
        return callParentDir(scope_, outTypedValue, call);
    }
    else if(functionName == "path")
    {
        // path function doesn't need the target type.  It's return type is independent of
        // the required targetType.
        return callPathFunction(scope_, outTypedValue, call);
        /*
        // path function doesn't need the target type.  It's return type is independent of
        // the required targetType.
        TypedValue typedValue;
        auto errorString = callPathFunction(scope_, &typedValue, call);
        if(errorString)
        {
            return errorString;
        }
        return typedValue.convertValueToType(outValue, targetType);
        */
    }
    else if(functionName == "findGitRepo")
    {
        return callFindGitRepo(scope_, outTypedValue, call);
    }
    else
    {
        writefln("%sError: unknown function \"%s\"", scope_.getFile().formatLocation(functionName), functionName);
        throw quit;
    }
}

// returns error string on error
ErrorString callBasename(IScope scope_, TypedValue* outTypedValue, Expression call)
{
    if(call.functionCall.args.length != 1)
    {
        writefln("Error: the 'basename' function takes 1 argument, but got %s", call.functionCall.args.length);
        throw quit;
    }
    Value argValue;
    {
        auto error = PrimitiveType.string_.interpretExpression(scope_, &argValue, call.functionCall.args[0]);
        if(error)
        {
            return error;
        }
    }
    {
        *outTypedValue = TypedValue(Value(baseName(argValue.string_)), PrimitiveType.string_);
        return ErrorString.null_;
    }
}
// returns error string on error
ErrorString callParentDir(IScope scope_, TypedValue* outTypedValue, Expression call)
{
    if(call.functionCall.args.length != 1)
    {
        writefln("Error: the 'parentDir' function takes 1 argument, but got %s", call.functionCall.args.length);
        throw quit;
    }
    Value argValue;
    {
        auto error = PrimitiveType.string_.interpretExpression(scope_, &argValue, call.functionCall.args[0]);
        if(error)
        {
            return error;
        }
    }
    {
        *outTypedValue = TypedValue(Value(dirName(argValue.string_)), PrimitiveType.dirpath);
        return ErrorString.null_;
    }
}

/**
Using a custom class for PathPieceType becuase it is unique from other
types.  It can accept values from the following primitive types:
  - string_
  - path
  - dirpath
  - dirname
and will also accept values from the types (filename, filepath) only if
it is the last piece (last argument of the path function).
*/
class PathPieceType : Type
{
    __gshared immutable instanceNotLastArg = new immutable PathPieceType(No.lastArg);
    __gshared immutable instanceLastArg    = new immutable PathPieceType(Yes.lastArg);
    static auto instance(Flag!"lastArg" lastArg) { return lastArg ? instanceLastArg : instanceNotLastArg; }

    Flag!"lastArg" lastArg;
    private this(Flag!"lastArg" lastArg) immutable
    {
        this.lastArg = lastArg;
    }

    // IBidmakeObject fields
    @property const(Type) getType() const { assert(0, "not implemented"); }
    @property Value asValue() { return Value(this); }
    @property TypedValue asTypedValue() { assert(0, "not implemented"); }
    final inout(IScope) tryAsScope() inout { assert(0, "not implemented"); }
    final inout(bidmake.analyzer.Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        assert(0, "not implemented");
    }
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        writefln("Error: you cannot call a path-function-arg");
        throw quit;
    }

    // Type fields
    @property override string shallowName() const { return "<path-function-arg>"; }
    final override inout(PrimitiveType) tryAsPrimitive() inout { return null; }
    final override inout(ListType) tryAsListType() inout { return null; }
    @property final override const(Type) getProcessType() const { return getType(); }
    final override bool isAssignableFrom(const(Type) src) const
    {
        auto srcAsPrimitive = src.tryAsPrimitive();
        if(srcAsPrimitive is null)
        {
            return false;
        }
        if(    srcAsPrimitive.name == PrimitiveTypeName.string_
            || srcAsPrimitive.name == PrimitiveTypeName.path
            || srcAsPrimitive.name == PrimitiveTypeName.dirpath
            || srcAsPrimitive.name == PrimitiveTypeName.dirname)
        {
            return true;
        }
        if(lastArg)
        {
            if(srcAsPrimitive.name.isFilePathOrName)
            {
                return true;
            }
        }
        return false;
    }
    final override bool secondCheckIsAssignableTo(const(Type) dst) const
    {
        // not sure if this is necessary to implement this.
        // I think in all cases the isAssignableFrom will be called instead
        assert(0, "not implemented");
    }
    final override void valueFormatter(StringSink sink, const(Value)* field) const
    {
        assert(0, "not implemented");
        //sink(values[field.sizet]);
    }
    final override inout(IBidmakeObject) tryValueAsBidmakeObject(inout(Value) value) const
    {
        return null;
    }
    final override ErrorString interpretString(IScope scope_, Value* outValue, string str) const
    {
        outValue.string_ = str;
        return ErrorString.null_; // success
    }
    override ErrorString interpretExpression(IScope scope_, Value* outValue, Expression expression) const
    {
        assert(0, "not implemented");
    }
    override ErrorString interpretStatement(IScope scope_, Value* outValue, StatementRangeReference statement) const
    {
        assert(0, "not implemented");
    }
}

// returns error string on error
ErrorString callPathFunction(IScope scope_, TypedValue* outValue, Expression call)
{
    auto pathBuilder = appender!(string)();

    foreach(argIndex, arg; call.functionCall.args)
    {
        auto lastArg =  (argIndex == call.functionCall.args.length - 1) ? Yes.lastArg : No.lastArg;

        Value value;
        auto error = defaultExpressionToValueEvaluator(arg, scope_, &value, PathPieceType.instance(lastArg));
        if(error)
        {
            writefln("HERE: error='%s'", error);
            return error;
        }
        if(pathBuilder.data.length == 0)
        {
            pathBuilder.put(value.string_);
        }
        else
        {
            if(value.string_.length == 0)
            {
                continue;
            }
            if(isPathSeparator(value.string_[0]))
            {
                return ErrorString("cannot append a rooted path to another path");
            }
            if(!isPathSeparator(pathBuilder.data[$-1]))
            {
                pathBuilder.put(defaultPathSeparatorChar);
            }
            pathBuilder.put(value.string_);
        }
    }

    *outValue = TypedValue(Value(pathBuilder.data), PrimitiveType.path);
    return ErrorString.null_; // success
}


ErrorString callFindGitRepo(IScope scope_, TypedValue* outTypedValue, Expression call)
{
    if(call.functionCall.args.length != 2)
    {
        writefln("Error: the 'findGitRepo' function takes 2 arguments, but got %s", call.functionCall.args.length);
        throw quit;
    }
    Value dirArgValue;
    {
        auto error = PrimitiveType.dirpath.interpretExpression(scope_, &dirArgValue, call.functionCall.args[0]);
        if(error)
        {
            return error;
        }
    }
    Value urlArgValue;
    {
        auto error = PrimitiveType.string_.interpretExpression(scope_, &urlArgValue, call.functionCall.args[1]);
        if(error)
        {
            return error;
        }
    }
    return callFindGitRepo(scope_, outTypedValue, dirArgValue.string_, urlArgValue.string_);
}
ErrorString callFindGitRepo(IScope scope_, TypedValue* outTypedValue, string dir, string url)
{
    //writefln("dir = '%s' url = '%s'", dir, url);

    auto absoluteDir = buildNormalizedPath(absolutePath(dir));
    auto repoRoot = insideGitRepo(absoluteDir);
    if(repoRoot is null)
    {
        writefln("findGitRepo failed because you are not inside a git repo");
        throw quit;
    }

    auto repoSuperDir = dirName(repoRoot);
    auto repoNameToFind = baseName(url);
    string repoPath = null;
    foreach(entry; dirEntries(repoSuperDir, SpanMode.shallow))
    {
        auto repoName = baseName(entry.name);
        if(repoName == repoNameToFind)
        {
            repoPath = entry.name;
            break;
        }
    }
    if(repoPath is null)
    {
        writefln("findGitRepo failed to find repo '%s' in path '%s' (url=%s)",
            repoNameToFind, repoSuperDir, url);
        throw quit;
    }

    //writefln("[DEBUG] Found repo '%s' at '%s'", repoNameToFind, repoPath);

    // TODO: should we check the URL in .git/config?

    *outTypedValue = TypedValue(Value(repoPath), PrimitiveType.dirpath);
    return ErrorString.null_;
}