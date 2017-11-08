module bidmake.builtinfunctions;

import std.stdio : writefln;
import std.conv : to;
import std.array : appender;
import std.typecons : Flag, Yes, No;

import util : unconst, quit, StringSink, defaultPathSeparatorChar, isPathSeparator;
import bidmake.parser : Expression, ExpressionType, BidmakeStatement, BidmakeStatementRangeReference;
import bidmake.analyzer;

// returns error string on error
string interpretCall(IScope scope_, Value* outValue, Type targetType, Expression expression)
    in { assert(expression.type == ExpressionType.functionCall); } body
{
    auto functionName = expression.functionName();
    if(functionName == "path")
    {
        // path function doesn't need the target type.  It's return type is independent of
        // the required targetType.
        return callPathFunction(scope_, outValue, expression);
    }
    else
    {
        writefln("%sError: unknown funciton \"%s\"", scope_.getFile.formatLocation(functionName), functionName);
        throw quit;
    }
}

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
    @property final string shallowTypeName() const { return "<path-function-arg>"; }
    @property final string processTypeName() const { return "<path-function-arg>"; }
    final inout(bidmake.analyzer.Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final string interpretAsValue(IScope scope_, Value* outValue, Type type)
    {
        assert(0, "not implemented");
    }
    final string interpretAsPrimitiveValue(IScope scope_, Value* outValue, PrimitiveType type)
    {
        return "the path-function-arg type itself cannot be interpreted as a value of primitive type " ~ type.name.to!string;
    }
    final void onCall(IScope callScope, BidmakeStatement statement)
    {
        writefln("Error: you cannot call a path-function-arg");
        throw quit;
    }

    // Type fields
    final override inout(PrimitiveType) tryAsPrimitive() inout { return null; }
    final override inout(ListType) tryAsListType() inout { return null; }
    final override bool isAssignableFrom(const(Type) src) const
    {
        assert(0, "not implemented");
        //return this is src;
    }
    final override bool secondCheckIsAssignableTo(const(Type) dst) const
    {
        auto dstAsPrimitive = dst.tryAsPrimitive();
        if(dstAsPrimitive is null)
        {
            return false;
        }
        if(    dstAsPrimitive.name == PrimitiveTypeName.string_
            || dstAsPrimitive.name == PrimitiveTypeName.path
            || dstAsPrimitive.name == PrimitiveTypeName.dirpath
            || dstAsPrimitive.name == PrimitiveTypeName.dirname)
        {
            return true;
        }
        if(lastArg)
        {
            if(    dstAsPrimitive.name == PrimitiveTypeName.filepath
                || dstAsPrimitive.name == PrimitiveTypeName.filename)
            {
                return true;
            }
        }
        return false;
    }
    final override void fieldFormatter(StringSink sink, const(Value)* field) const
    {
        assert(0, "not implemented");
        //sink(values[field.sizet]);
    }
    final override string interpretString(IScope scope_, Value* outValue, string str)
    {
        outValue.string_ = str;
        return null; // success
    }
    override string interpretExpression(IScope scope_, Value* outValue, Expression expression)
    {
        assert(0, "not implemented");
    }
    override string tryProcessProperty(IScope scope_, Value* outValue, BidmakeStatementRangeReference statement)
    {
        assert(0, "not implemented");
    }
}

// returns error string on error
string callPathFunction(IScope scope_, Value* outValue, Expression call)
{
    auto pathBuilder = appender!(string)();
    foreach(argIndex, arg; call.functionCall.args)
    {
        auto lastArg =  (argIndex == call.functionCall.args.length - 1) ? Yes.lastArg : No.lastArg;

        Value value;
        auto error = defaultExpressionToValueEvaluator(arg, scope_, &value, PathPieceType.instance(lastArg).unconst);
        if(error)
        {
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
                return "cannot append a rooted path to another path";
            }
            if(!isPathSeparator(pathBuilder.data[$-1]))
            {
                pathBuilder.put(defaultPathSeparatorChar);
            }
            pathBuilder.put(value.string_);
        }
    }
    outValue.string_ = pathBuilder.data;
    return null; // success
}