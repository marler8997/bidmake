module bidmake.analyzer;

import std.typecons : Flag, Yes, No, Rebindable, rebindable;
import std.traits : isDynamicArray, hasUDA, getUDAs, isArray;
import std.array  : Appender, appender;
import std.range  : ElementType;
import std.algorithm: count;
import std.format : format, formattedWrite;
import std.conv   : to;
import std.path   : baseName, stripExtension, buildPath, buildNormalizedPath;
import std.file   : exists, isDir, dirEntries, SpanMode;
import std.stdio;
import std.process : environment;

import more.format : StringSink, DelegateFormatter;
import util : immutable_zstring, quit, equalContains, isContains, formatDir,
              PeeledName, peelQualifiedName, containsPathSeperator, readFile, DirAndFile;

static import more.esb;
import more.esb : ExpressionType, Expression, Statement, StatementRangeReference;

import bidmake.builtincontractors;
import bidmake.builtinfunctions : interpretCall;

__gshared string globalRepoPath;

struct ErrorString
{
    static auto null_() { return ErrorString(); }

    string error;
    @property auto opCast(T)()
    {
        static if( is(T == bool) )
        {
            return error != null;
        }
        else static assert(0, "Cannot cast an ErrorString to " ~ T.stringof);
    }
    string toString() const { return error; }
}

interface IBidmakeObject
{
    @property const(Type) getType() const;
    @property Value asValue();
    inout(IScope) tryAsScope() inout;
    inout(Interface) tryAsInterface() inout;
    inout(Type) tryAsType() inout;
    inout(Define) tryAsDefine() inout;
    ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type);
    TypedValue onCall(IScope callScope, StatementRangeReference statementRange);
}
@property TypedValue asTypedValue(IBidmakeObject bidmakeObject)
{
    return TypedValue(bidmakeObject.asValue, bidmakeObject.getType);
}
@property string shallowTypeName(const(IBidmakeObject) obj)
{
    return obj.getType.shallowName();
}

abstract class Type : IBidmakeObject
{
    // IBidmakeObject Fields
    inout(Type) tryAsType() inout { return this; }

    @property abstract string shallowName() const;
    abstract inout(PrimitiveType) tryAsPrimitive() inout;
    abstract inout(ListType) tryAsListType() inout;

    // returns the types that is processed when
    @property abstract const(Type) getProcessType() const;

    abstract bool isAssignableFrom(const(Type) src) const;
    // Note: this function is only called if the dst type does not
    //       know about the src type.  So this function will always be called
    //       inside dst.isAssignableFrom(this).
    protected abstract bool secondCheckIsAssignableTo(const(Type) dst) const;

    final auto formatValue(Value* value) const
    {
        static struct Formatter
        {
            const(Type) type;
            Value *value;
            void toString(StringSink sink) const
            {
                type.valueFormatter(sink, value);
            }
        }
        return Formatter(this, value);
    }

    // TODO: add an isValueSet method
    abstract void valueFormatter(StringSink sink, const(Value)* value) const;
    abstract inout(IBidmakeObject) tryValueAsBidmakeObject(inout(Value) value) const;
    // returns: error message on error
    abstract ErrorString interpretString(IScope scope_, Value* outValue, string str) const;
    // returns: error message on error
    abstract ErrorString interpretExpression(IScope scope_, Value* outValue, Expression expression) const;
    // returns: error message on error
    abstract ErrorString interpretStatement(IScope scope_, Value* outValue, StatementRangeReference statement) const;
}
@property string processTypeName(const(Type) obj)
{
    return obj.getProcessType.shallowName();
}

enum PrimitiveTypeName
{
    void_,
    bool_,
    string_,  // just a generic string
    path,     // a filesystem path, could be a directory or a file
    dirpath,  // a filesystem path that represents a directory
    filepath, // a filesystem path that represents a file
    dirname,  // a name that represents a directory.  it does not contain a path.
    filename, // a name that represesnts a file. it does not contain a path.
}
@property string valueUnionField(PrimitiveTypeName typeName)
    in { assert(typeName != PrimitiveTypeName.void_); } body
{
    return PrimitiveType.table[typeName].valueUnionField;
}
@property bool isFilePathOrName(PrimitiveTypeName typeName)
{
    return typeName == PrimitiveTypeName.filepath || typeName == PrimitiveTypeName.filename;
}
@property bool isDirPathOrName(PrimitiveTypeName typeName)
{
    return typeName == PrimitiveTypeName.dirpath || typeName == PrimitiveTypeName.dirname;
}

class TypeType : Type
{
    __gshared static immutable instance = new immutable TypeType();
    this() immutable { }
    // IBidmakeObject fields
    @property const(Type) getType() const { return this; }
    @property Value asValue() { return Value(this); }
    // todo: the typetype may actually have it's own fields, so it would be a "scope"
    final inout(IScope) tryAsScope() inout { return null; }
    final inout(Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        assert(0, "not implemented");
    }
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        writefln("Error: you cannot call the type type");
        throw quit;
    }
    // Type fields
    @property override string shallowName() const { return "typetype"; }
    final override inout(PrimitiveType) tryAsPrimitive() inout { return null; }
    final override inout(ListType) tryAsListType() inout { return null; }
    @property final override const(Type) getProcessType() const { return getType(); }
    final override bool isAssignableFrom(const(Type) src) const
    {
        assert(0, "not implemented");
    }
    final override bool secondCheckIsAssignableTo(const(Type) dst) const
    {
        assert(0, "not implemented");
    }
    final override void valueFormatter(StringSink sink, const(Value)* field) const
    {
        assert(0, "not implemented");
    }
    final override inout(IBidmakeObject) tryValueAsBidmakeObject(inout(Value) value) const
    {
        auto type = value.bidmakeObject.tryAsType();
        assert(type);
        return type;
    }
    final override ErrorString interpretString(IScope scope_, Value* outValue, string str) const
    {
        assert(0, "not implemented");
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

auto get(PrimitiveTypeName name)
{
    return PrimitiveType.get(name);
}
class PrimitiveType : Type
{
    static immutable(PrimitiveType) get(PrimitiveTypeName name)
    {
        auto entry = table[name];
        assert(entry);
        return entry;
    }
    __gshared static immutable void_    = new immutable PrimitiveType(PrimitiveTypeName.void_   , "void", null);
    __gshared static immutable bool_    = new immutable PrimitiveType(PrimitiveTypeName.bool_ , "bool", "bool_");
    __gshared static immutable string_  = new immutable PrimitiveType(PrimitiveTypeName.string_ , "string", "string_");
    __gshared static immutable path     = new immutable PrimitiveType(PrimitiveTypeName.path    , "path", "string_");
    __gshared static immutable dirpath  = new immutable PrimitiveType(PrimitiveTypeName.dirpath , "dirpath", "string_");
    __gshared static immutable filepath = new immutable PrimitiveType(PrimitiveTypeName.filepath , "filepath", "string_");
    /*
    __gshared static immutable void_ = new immutable PrimitiveType(PrimitiveTypeName.void_   , "void", null);
    static auto void_() { return staticTypes[PrimitiveTypeName.void_]; }
    static auto string_() { return staticTypes[PrimitiveTypeName.string_]; }
    */
    private static __gshared immutable PrimitiveType[] table = [
        PrimitiveTypeName.void_    : void_,
        PrimitiveTypeName.bool_    : bool_,
        PrimitiveTypeName.string_  : string_,
        PrimitiveTypeName.path     : path,
        PrimitiveTypeName.dirpath  : dirpath,
        PrimitiveTypeName.filepath  : filepath,
        PrimitiveTypeName.dirname  : new immutable PrimitiveType(PrimitiveTypeName.dirname , "dirname", "string_"),
        PrimitiveTypeName.filename : new immutable PrimitiveType(PrimitiveTypeName.filename, "filename", "string_"),
    ];

    PrimitiveTypeName name;
    string typeNameString;
    string valueUnionField;
    private this(PrimitiveTypeName name, string typeNameString, string valueUnionField) immutable
    {
        this.name = name;
        this.typeNameString = typeNameString;
        this.valueUnionField = valueUnionField;
    }

    // IBidmakeObject fields
    @property const(Type) getType() const { return TypeType.instance; }
    @property Value asValue() { return Value(this); }
    // todo: primitive types may have their own fields, so in the future it may be a "scope"
    final inout(IScope) tryAsScope() inout { return null; }
    final inout(Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        assert(0, "not implemented");
    }
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        writefln("Error: you cannot call an object of type \"%s\"", typeNameString);
        throw quit;
    }

    // Type fields
    @property override string shallowName() const { return typeNameString; }
    final override inout(PrimitiveType) tryAsPrimitive() inout { return this; }
    final override inout(ListType) tryAsListType() inout { return null; }
    @property final override const(Type) getProcessType() const { return getType(); }
    final override bool isAssignableFrom(const(Type) src) const
    {
        auto srcAsPrimitiveType = src.tryAsPrimitive();
        if(srcAsPrimitiveType is null)
        {
            return src.secondCheckIsAssignableTo(this);
        }
        final switch(name)
        {
            case PrimitiveTypeName.void_:
                return srcAsPrimitiveType.name == PrimitiveTypeName.void_;
            case PrimitiveTypeName.bool_:
                return srcAsPrimitiveType.name == PrimitiveTypeName.bool_;
            case PrimitiveTypeName.string_:
                return srcAsPrimitiveType.name == PrimitiveTypeName.string_
                    || srcAsPrimitiveType.name == PrimitiveTypeName.path
                    || srcAsPrimitiveType.name == PrimitiveTypeName.dirpath
                    || srcAsPrimitiveType.name == PrimitiveTypeName.filepath
                    || srcAsPrimitiveType.name == PrimitiveTypeName.dirname
                    || srcAsPrimitiveType.name == PrimitiveTypeName.filename;
            case PrimitiveTypeName.path:
                return
                       srcAsPrimitiveType.name == PrimitiveTypeName.path
                    || srcAsPrimitiveType.name == PrimitiveTypeName.dirpath
                    || srcAsPrimitiveType.name == PrimitiveTypeName.filepath
                    || srcAsPrimitiveType.name == PrimitiveTypeName.dirname
                    || srcAsPrimitiveType.name == PrimitiveTypeName.filename;
            case PrimitiveTypeName.dirpath:
                return srcAsPrimitiveType.name == PrimitiveTypeName.path
                    || srcAsPrimitiveType.name == PrimitiveTypeName.dirpath;
            case PrimitiveTypeName.filepath:
                return srcAsPrimitiveType.name == PrimitiveTypeName.path
                    || srcAsPrimitiveType.name == PrimitiveTypeName.filepath;
            case PrimitiveTypeName.dirname:
                return srcAsPrimitiveType.name == PrimitiveTypeName.dirname;
            case PrimitiveTypeName.filename:
                return srcAsPrimitiveType.name == PrimitiveTypeName.filename;
        }
    }
    final override bool secondCheckIsAssignableTo(const(Type) dst) const
    {
        return false;
    }
    final override void valueFormatter(StringSink sink, const(Value)* field) const
    {
        if(   name == PrimitiveTypeName.string_
           || name == PrimitiveTypeName.path
           || name == PrimitiveTypeName.dirpath
           || name == PrimitiveTypeName.filepath
           || name == PrimitiveTypeName.dirname
           || name == PrimitiveTypeName.filename
        ) {
            sink(field.string_);
        }
        else assert(0, "valueFormatter for type " ~ name.to!string ~ " is not implemented");
    }
    final override inout(IBidmakeObject) tryValueAsBidmakeObject(inout(Value) value) const
    {
        return null;
    }
    final override ErrorString interpretString(IScope scope_, Value* outValue, string str) const
    {
        bool cannotContainPathSeparators;

        if(   name == PrimitiveTypeName.dirname
           || name == PrimitiveTypeName.filename)
        {
            cannotContainPathSeparators = true;
        }
        else
        {
            cannotContainPathSeparators = false;
        }

        if(cannotContainPathSeparators
           || name == PrimitiveTypeName.string_
           || name == PrimitiveTypeName.path
           || name == PrimitiveTypeName.dirpath
           || name == PrimitiveTypeName.filepath
        ) {
            if(cannotContainPathSeparators && containsPathSeperator(str))
            {
                return ErrorString("cannot contain path seperators");
            }
            outValue.string_ = str;
            return ErrorString.null_;
        }
        return ErrorString("interpretString for primitive type '" ~ name.to!string ~ "' is not implemented");
    }
    final override ErrorString interpretExpression(IScope scope_, Value* outValue, Expression expression) const
    {
        return defaultExpressionToValueEvaluator(expression, scope_, outValue, this);
    }
    final override ErrorString interpretStatement(IScope scope_, Value* outValue, StatementRangeReference statement) const
    {
        // TODO: maybe returning an error string instead would make more sense
        statement.assertNoBlock(scope_).assertExpressionCount(1);
        return interpretExpression(scope_, outValue, statement.front);
    }
}
class Enum : Type, IScope
{
    string name;
    string[] values;
    IScope parentScope;
    this(string name, string[] values, IScope parentScope)
    {
        this.name = name;
        this.values = values;
        this.parentScope = parentScope;
    }

    size_t tryFindValue(const(char)[] name) const
    {
        foreach(i, value; values)
            if(name == value)
                return i;
        return size_t.max;
    }

    // IBidmakeObject fields
    @property const(Type) getType() const { return TypeType.instance; }
    @property Value asValue() { return Value(this); }
    final inout(IScope) tryAsScope() inout { return this; }
    final inout(Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        // TODO: assign the Enum type itself to outValue
        assert(0, "not implemented");
    }
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        writefln("Error: you cannot call an enum");
        throw quit;
    }

    // IScope Fields
    @property inout(BidmakeFile) tryAsFile() inout { return null; }
    @property IScope getParentScope() { return parentScope; }
    final TypedValue tryGetTypedValueImpl(string name)
    {
        auto value = tryFindValue(name);
        if (value == size_t.max)
        {
            writefln("Error: enum type '%s' does not have value '%s'", this.name, name);
            throw quit;
        }
        return TypedValue(Value(value), this);
    }
    final void addInclude(BidmakeFile include)      { assert(0, "not implemented or not supported"); }
    final void addImport(BidmakeFile import_)       { assert(0, "not implemented or not supported"); }
    final void addDefine(Define define)             { assert(0, "not implemented or not supported"); }
    final void addInterface(Interface interface_)   { assert(0, "not implemented or not supported"); }
    final void addContractor(Contractor contractor) { assert(0, "not implemented or not supported"); }
    final void addContract(Contract contract)       { assert(0, "not implemented or not supported"); }
    final void addEnum(Enum enum_)                  { assert(0, "not implemented or not supported"); }

    // Type fields
    @property override string shallowName() const { return name; }
    final override inout(PrimitiveType) tryAsPrimitive() inout { return null; }
    final override inout(ListType) tryAsListType() inout { return null; }
    @property final override const(Type) getProcessType() const { return getType(); }
    final override bool isAssignableFrom(const(Type) src) const
    {
        return this is src;
    }
    final override bool secondCheckIsAssignableTo(const(Type) dst) const
    {
        assert(0, "not implemented");
        //return this is src;
    }
    final override void valueFormatter(StringSink sink, const(Value)* field) const
    {
        sink(values[field.sizet]);
    }
    final override inout(IBidmakeObject) tryValueAsBidmakeObject(inout(Value) value) const
    {
        assert(0, "not implemented");
    }
    final override ErrorString interpretString(IScope scope_, Value* outValue, string str) const
    {
        assert(0, "not implemented");
    }
    override ErrorString interpretExpression(IScope scope_, Value* outValue, Expression expression) const
    {
        // special case for symbols
        if(expression.type == ExpressionType.symbol)
        {
            {
                auto result = tryFindValue(expression.source);
                if (result != size_t.max)
                {
                    outValue.sizet = result;
                    return ErrorString.null_; // success
                }
            }
            auto error = defaultExpressionToValueEvaluator(expression, scope_, outValue, this);
            if(error)
            {
                return ErrorString("it does not match any of the enum values and " ~ error.error);
            }
            return ErrorString.null_; // success
        }
        else
        {
            return defaultExpressionToValueEvaluator(expression, scope_, outValue, this);
        }
    }
    override ErrorString interpretStatement(IScope scope_, Value* outValue, StatementRangeReference statement) const
    {
        statement.assertNoBlock(scope_).assertExpressionCount(1);
        return interpretExpression(scope_, outValue, statement.front);
    }
}
class ListType : Type
{
    const(Type) elementType;
    this(const(Type) elementType)
    {
        this.elementType = elementType;
    }
    // IBidmakeObject fields
    @property const(Type) getType() const { return TypeType.instance; }
    @property Value asValue() { return Value(this); }
    final inout(IScope) tryAsScope() inout { return null; }
    final inout(Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        // TODO: assign the ListType itself to outValue
        assert(0, "not implemented");
    }
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        writefln("Error: you cannot call a list type");
        throw quit;
    }

    // Type fields
    @property override string shallowName() const { return "list"; }
    final override inout(PrimitiveType) tryAsPrimitive() inout { return null; }
    final override inout(ListType) tryAsListType() inout { return this; }
    @property final override const(Type) getProcessType() const { return elementType; }
    final override bool isAssignableFrom(const(Type) src) const
    {
        auto srcAsListType = src.tryAsListType();
        return srcAsListType && this.elementType.isAssignableFrom(srcAsListType.elementType);
    }
    final override bool secondCheckIsAssignableTo(const(Type) dst) const
    {
        assert(0, "not implemented");
    }
    final override void valueFormatter(StringSink sink, const(Value)* field) const
    {
        sink("[");
        string prefix = "";
        foreach(ref element; field.list)
        {
            sink(prefix);
            prefix = ", ";
            elementType.valueFormatter(sink, &element);
        }
        sink("]");
    }
    final override inout(IBidmakeObject) tryValueAsBidmakeObject(inout(Value) value) const
    {
        assert(0, "not implemented");
    }
    final override ErrorString interpretString(IScope scope_, Value* outValue, string str) const
    {
        assert(0, "not implemented");
    }
    override ErrorString interpretExpression(IScope scope_, Value* outValue, Expression expression) const
    {
        assert(0, "ListType.interpretExpression not implemented");
    }
    override ErrorString interpretStatement(IScope scope_, Value* outValue, StatementRangeReference statement) const
    {
        Value newElement;
        auto error = elementType.interpretStatement(scope_, &newElement, statement);
        if(error)
        {
            return error;
        }
        outValue.list ~= newElement;
        return ErrorString.null_;
    }
}
abstract class BidmakeObjectType : Type
{
    // IBidmakeObject field
    @property const(Type) getType() const { return TypeType.instance; }
    @property Value asValue() { return Value(this); }
    // TODO: maybe in the future the type will have some symbols you can access
    final inout(IScope) tryAsScope() inout { return null; }
    final inout(Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    abstract ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type);
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        writefln("Error: you cannot call a bidmake object type");
        throw quit;
    }
    // Type fields
    final override inout(PrimitiveType) tryAsPrimitive() inout { return null; }
    final override inout(ListType) tryAsListType() inout { return null; }
    @property final override const(Type) getProcessType() const { return getType(); }
    final override bool isAssignableFrom(const(Type) src) const
    {
        assert(0, "not implemented");
    }
    final override bool secondCheckIsAssignableTo(const(Type) dst) const
    {
        assert(0, "not implemented");
    }
    final override void valueFormatter(StringSink sink, const(Value)* field) const
    {
        assert(0, "not implemented");
    }
    final override inout(IBidmakeObject) tryValueAsBidmakeObject(inout(Value) value) const
    {
        return value.bidmakeObject;
    }
    final override ErrorString interpretString(IScope scope_, Value* outValue, string str) const
    {
        assert(0, "not implemented");
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

interface IScope
{
    @property inout(BidmakeFile) tryAsFile() inout;
    @property IScope getParentScope();
    TypedValue tryGetTypedValueImpl(string name);
    void addInclude(BidmakeFile include);
    void addImport(BidmakeFile import_);
    void addDefine(Define define);
    void addInterface(Interface interface_);
    void addContractor(Contractor contractor);
    void addContract(Contract contract);
    void addEnum(Enum enum_);
}
TypedValue tryGetTypedValue(IScope scope_, string name)
{
    // handle special properies
    if(name == "sourceFile")
    {
        return TypedValue(Value(scope_.getFile().dirAndFile.pathFileCombo), PrimitiveType.filepath);
    }
    return scope_.tryGetTypedValueImpl(name);
}

class UniversalScope : IScope
{
    __gshared static instance = new UniversalScope();
    private this() { }
    @property final inout(BidmakeFile) tryAsFile() inout { return null; }
    @property final IScope getParentScope() { return null; }
    final TypedValue tryGetTypedValueImpl(string name)
    {
        if (name == "true")
            return TypedValue(Value(true), PrimitiveType.bool_);
        if (name == "false")
            return TypedValue(Value(false), PrimitiveType.bool_);
        if (name == "os")
        {
            version(Windows) { return TypedValue(Value("windows"), PrimitiveType.string_); }
            else version(linux) { return TypedValue(Value("linux"), PrimitiveType.string_); }
            else static assert(0, "Variable 'os' not implemented for this platform");
        }
        if (name == "userHome")
        {
            version(Windows) { return TypedValue(Value(environment["USERPROFILE"]), PrimitiveType.string_); }
            else version(linux) { return TypedValue(Value(environment["HOME"]), PrimitiveType.string_); }
            else static assert(0, "Variable 'os' not implemented for this platform");
        }
        return TypedValue.null_;
    }
    final void addInclude(BidmakeFile include)      { assert(0, "not implemented or not supported"); }
    final void addImport(BidmakeFile import_)       { assert(0, "not implemented or not supported"); }
    final void addDefine(Define define)             { assert(0, "not implemented or not supported"); }
    final void addInterface(Interface interface_)   { assert(0, "not implemented or not supported"); }
    final void addContractor(Contractor contractor) { assert(0, "not implemented or not supported"); }
    final void addContract(Contract contract)       { assert(0, "not implemented or not supported"); }
    final void addEnum(Enum enum_)                  { assert(0, "not implemented or not supported"); }
}

auto getFile(IScope scope_)
{
    for(;; scope_ = scope_.getParentScope)
    {
        assert(scope_, "code bug");
        auto file = scope_.tryAsFile;
        if(file)
        {
            return file;
        }
    }
}
void assertNoSymbol(IScope scope_, string symbol, lazy string nameForMessage)
{
    auto existing = scope_.tryGetTypedValue(symbol);
    if(!existing.isNull)
    {
        writefln("%sError: %s \"%s\" conflicts with existing %s",
            scope_.getFile().formatLocation(symbol), nameForMessage, symbol, existing.type.shallowName);
        throw quit;
    }
}

// Assumption: symbol is a slice of bidmakeFile.contents.  the reason is
//             that is is used for the error message
TypedValue lookupUnqualifiedSymbol(IScope scope_, string symbol)
{
    auto originalScope = scope_;
    for(;;)
    {
        auto entry = scope_.tryGetTypedValue(symbol);
        if(!entry.isNull)
        {
            return entry;
        }
        auto parentScope = scope_.getParentScope();
        if(parentScope is null)
        {
            writefln("%sError: no definition for symbol \"%s\"",
                originalScope.getFile().formatHintedLocation(symbol), symbol);
            throw quit;
        }
        scope_ = parentScope;
    }
}
// Note: will throw an exception if symbol does not exist (no need to check returnValue.isNull)
TypedValue lookupQualifiedSymbol(IScope scope_, string symbol)
{
    //writefln("[DEBUG] lookupQualifiedSymbol \"%s\" in %s", symbol, scope_.formatScopeContext);
    auto peeled = PeeledName(null, symbol);
    for(;;)
    {
        peeled = peelQualifiedName(peeled.rest);
        if(peeled.rest is null)
        {
            break;
        }
        //writefln("[DEBUG]   - getScope \"%s\" in %s", peeled.nextName, scope_.formatScopeContext);
        auto obj = lookupUnqualifiedSymbol(scope_, peeled.nextName);
        auto newScope = obj.tryAsScope();
        if(newScope is null)
        {
            writefln("%sError: symbol \"%s\" is not a scope, it's type is '%s'",
                scope_.getFile().formatLocation(peeled.nextName), peeled.nextName, obj.type.shallowName());
            throw quit;
        }
        scope_ = newScope;
    }

    //writefln("[DEBUG]   - get \"%s\" in %s", peeled.nextName, scope_.formatScopeContext);
    return lookupUnqualifiedSymbol(scope_, peeled.nextName);
}

const(Type) lookupType(IScope scope_, string typeSymbol)
{
    foreach(primitiveType; PrimitiveType.table)
    {
        if(typeSymbol == primitiveType.typeNameString)
        {
            return primitiveType;
        }
    }

    auto obj = lookupQualifiedSymbol(scope_, typeSymbol);
    auto objAsType = obj.tryAsType();
    if(objAsType is null)
    {
        writefln("%sError: expected a type but got \"%s\"",
            scope_.getFile().formatLocation(typeSymbol), obj.type.shallowName);
        throw quit;
    }
    return objAsType;
}

// This shouldn't be called directly to evaluate an expression, it's only used as a common
// implementation for other types to call.  To evaluate an expression, you should call
// <type>.interpretExpression. This function will just forward the call to other objects
// to evaluate it further.
ErrorString defaultExpressionToValueEvaluator(Expression expression, IScope scope_, Value *outValue, const(Type) targetType)
{
    //writefln("[DEBUG] converting expression '%s' to %s", expression, targetType.shallowName);
    final switch(expression.type)
    {
        case ExpressionType.symbol:
            assert(expression.source is expression.string_); // sanity check
            auto resolved = lookupQualifiedSymbol(scope_, expression.source);
            return resolved.convertValueToType(outValue, targetType);
        case ExpressionType.string_:
            return targetType.interpretString(scope_, outValue, expression.string_);
        case ExpressionType.functionCall:
            TypedValue typedValue;
            auto errorString = interpretCall(scope_, &typedValue, targetType, expression);
            if(errorString)
            {
                return errorString;
            }
            return typedValue.convertValueToType(outValue, targetType);
    }
}

Appender!(BidmakeFile[]) globalFilesLoaded;
BidmakeFile loadBidmakeFile(string pathFileCombo, Flag!"parse" parse)
{
    foreach(alreadyLoaded; globalFilesLoaded.data)
    {
        if(alreadyLoaded.dirAndFile.pathFileCombo == pathFileCombo)
        {
            // TODO: this message is very helpful for debugging, should be an option to enable it
            //writefln("[DEBUG] file \"%s\" has already been loaded", pathFileCombo);
            if(parse)
            {
                alreadyLoaded.parse();
            }
            return alreadyLoaded;
        }
    }
    // TODO: this message is very helpful for debugging, should be an option to enable it
    //writefln("[DEBUG] reading \"%s\"", pathFileCombo);
    auto contents = cast(immutable_zstring)readFile(pathFileCombo);
    BidmakeFile bidmakeFile = new BidmakeFile(pathFileCombo, contents);
    if(parse)
    {
        bidmakeFile.parse();
    }
    globalFilesLoaded.put(bidmakeFile);
    return bidmakeFile;
}

class BidmakeFileType : BidmakeObjectType
{
    __gshared static immutable instance = new immutable BidmakeFileType();
    //
    // Type fields
    //
    @property override string shallowName() const { return "file"; }
    final override ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        if(type !is instance)
        {
            return ErrorString(format("cannot convert object of type 'file' to type '%s'", type.shallowName));
        }
        outValue.bidmakeObject = this;
        return ErrorString.null_; // success
    }
}

enum BidmakeFileState
{
    initial,
    loaded,
    parsed,
    analyzed,
}

class BidmakeFile : IBidmakeObject, IScope
{
    BidmakeFileState state;
    DirAndFile dirAndFile;
    string importName;

    immutable_zstring contents;
    Statement[] block;

    BidmakeFile redirect;
    private BidmakeFile[] imports;
    BidmakeFile[] includes;
    private Enum[] enums;
    private Define[] defines;
    private Interface[] interfaces;
    private Contractor[] contractors;
    Contract[] contracts;

    this(string pathFileCombo, immutable_zstring contents)
    {
        this.state = BidmakeFileState.loaded;
        this.dirAndFile = DirAndFile(pathFileCombo);
        this.importName = baseName(pathFileCombo).stripExtension();
        this.contents = contents;
    }

    void parse() in { assert(state >= BidmakeFileState.loaded); } body
    {
        if(this.state < BidmakeFileState.parsed)
        {
            this.block = more.esb.parse(contents, dirAndFile.pathFileCombo);
            this.state = BidmakeFileState.parsed;
        }
    }

    @property final auto pathFileCombo() const { return dirAndFile.pathFileCombo; }
    @property final auto dir() const { return dirAndFile.dir; }

    //
    // IScope Functions
    //
    @property inout(BidmakeFile) tryAsFile() inout { return this; }
    @property IScope getParentScope() { return UniversalScope.instance; }
    final TypedValue tryGetTypedValueImpl(string name)
    {
        //writefln("[DEBUG] tryGetTypedValueImpl(file=%s, name=%s)", this, name);
        foreach(import_; imports)
        {
            if(import_.importName == name)
            {
                return import_.asTypedValue;
            }
        }
        // For now all return is enums and interfaces
        foreach(enum_; enums)
        {
            if(enum_.name == name)
            {
                return enum_.asTypedValue;
            }
        }
        foreach(define; defines)
        {
            if(define.name == name)
            {
                return define.asTypedValue;
            }
        }
        foreach(interface_; interfaces)
        {
            if(interface_.name == name)
            {
                return interface_.asTypedValue;
            }
        }
        foreach(include; includes)
        {
            auto result = include.tryGetTypedValue(name);
            if(!result.isNull)
            {
                return result;
            }
        }
        return TypedValue.null_;
    }
    final void addInclude(BidmakeFile include)      { includes ~= include; }
    final void addImport(BidmakeFile import_)       { imports ~= import_; }
    final void addDefine(Define define)             { defines ~= define; }
    final void addInterface(Interface interface_)   { interfaces ~= interface_; }
    final void addContractor(Contractor contractor) { contractors ~= contractor; }
    final void addContract(Contract contract)       { contracts ~= contract; }
    final void addEnum(Enum enum_)                  { enums ~= enum_; }

    static struct LocationFormatter
    {
        BidmakeFile file;
        size_t lineNumber;
        this(BidmakeFile file, size_t lineNumber)
        {
            this.file = file;
            this.lineNumber = lineNumber;
        }
        this(BidmakeFile file, immutable(char)* sourcePtr)
        {
            this.file = file;
            this.lineNumber = 1 + count(file.contents[0 .. sourcePtr - file.contents.ptr], '\n');
        }
        void toString(StringSink sink) const
        {
            if(lineNumber > 0)
            {
                formattedWrite(sink, "%s(%s) ", file.pathFileCombo, lineNumber);
            }
            else
            {
                formattedWrite(sink, "%s: ", file.pathFileCombo);
            }
        }
    }
    private final LocationFormatter tryFormatHintedLocation(immutable(char)* sourcePtr)
    {
        if(sourcePtr >= contents.ptr && sourcePtr <= contents.ptr + contents.length)
        {
            return formatLocation(sourcePtr);
        }
        foreach(include; includes)
        {
            auto result = include.tryFormatHintedLocation(sourcePtr);
            if(result.lineNumber > 0)
            {
                return result;
            }
        }
        foreach(import_; imports)
        {
            auto result = import_.tryFormatHintedLocation(sourcePtr);
            if(result.lineNumber > 0)
            {
                return result;
            }
        }
        return LocationFormatter(null, 0);
    }
    final LocationFormatter formatHintedLocation(immutable(char)* sourcePtr)
    {
        auto result = tryFormatHintedLocation(sourcePtr);
        if(result.file)
        {
            return result;
        }
        return LocationFormatter(this, 0);
    }
    pragma(inline)
    final LocationFormatter formatHintedLocation(string source)
    {
        return formatHintedLocation(source.ptr);
    }

    pragma(inline)
    @property final LocationFormatter formatLocation(string str)
        in { assert(str.ptr >= contents.ptr &&
                    str.ptr <= contents.ptr + contents.length); } body
    {
        return formatLocation(str.ptr);
    }
    @property final LocationFormatter formatLocation(immutable(char)* sourcePtr)
        in { assert(sourcePtr >= contents.ptr &&
                    sourcePtr <= contents.ptr + contents.length); } body
    {
        return LocationFormatter(this, sourcePtr);
    }

    void findContractors(Appender!(Contractor[]) outList, Contract contract, string action)
    {
        assert(redirect == this);
        foreach(contractor; contractors)
        {
            if(contractor.supports(contract, action))
            {
                outList.put(contractor);
            }
        }
        foreach(import_; imports)
        {
            import_.findContractors(outList, contract, action);
        }
        foreach(include; includes)
        {
            include.findContractors(outList, contract, action);
        }
    }

    //
    // IBidmakeObject Functions
    //
    @property const(Type) getType() const { return BidmakeFileType.instance; }
    @property Value asValue() { return Value(this); }
    final inout(IScope) tryAsScope() inout { return this; }
    inout(Interface) tryAsInterface() inout { return null; }
    inout(Type) tryAsType() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        assert(0, "not implemented");
    }
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        writefln("Error: %s is a file, you cannot call it");
        throw quit;
    }

    override string toString() const
    {
        return dirAndFile.pathFileCombo;
    }
}

class Define : IBidmakeObject
{
    Value value;
    const(Type) type;
    string name;
    this(Value value, const(Type) type, string name)
    {
        this.value = value;
        this.type = type;
        this.name = name;
    }

    //
    // IBidmakeObject members
    //
    @property const(Type) getType() const { return type; }
    @property Value asValue() { return value; }
    final inout(IScope) tryAsScope() inout
    {
        auto bidmakeObj = type.tryValueAsBidmakeObject(value);
        if(bidmakeObj)
        {
            return bidmakeObj.tryAsScope();
        }
        return null;
    }
    inout(Interface) tryAsInterface() inout { assert(0, "not implemented"); }
    inout(Type) tryAsType() inout { assert(0, "not implemented"); }
    inout(Define) tryAsDefine() inout { return this; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        if(this.type.isAssignableFrom(type))
        {
            *outValue = this.value;
            return ErrorString.null_;
        }
        return ErrorString(format(
            "a value of type \"%s\" cannot be assigned to type \"%s\"",
            type.shallowTypeName, this.type.shallowTypeName));
    }
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        assert(0, "not implemented");
        //assert(0, "cannot call a define variable");
    }
}

struct FieldID
{
    pragma(inline) @property static FieldID null_() { return FieldID(size_t.max); }
    size_t index;
    @property bool isNull() const { return index == size_t.max; }
}

class InterfaceType : BidmakeObjectType
{
    __gshared static immutable instance = new immutable InterfaceType();
    //
    // Type fields
    //
    @property override string shallowName() const { return "interface"; }
    final override ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        if(type !is instance)
        {
            return ErrorString(format(
                "cannot convert object of type 'interface' to type '%s'", type.shallowName));
        }
        outValue.bidmakeObject = this;
        return ErrorString.null_; // success
    }
}

struct InterfaceField
{
    Rebindable!(const(Type)) type;
    string name;
    bool required;
    bool hasDefault;
    Statement default_;
}
abstract class Interface : IBidmakeObject, IScope
{
    string name;
    IScope parentScope;
    this(string name, IScope parentScope)
    {
        this.name = name;
        this.parentScope = parentScope;
    }
    // IBidmakeObject members
    @property const(Type) getType() const { return InterfaceType.instance; }
    @property Value asValue() { return Value(this); }
    final inout(IScope) tryAsScope() inout { return this; }
    inout(Interface) tryAsInterface() inout { return this; }
    inout(Type) tryAsType() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        assert(0, "not implemented");
    }
    TypedValue onCall(IScope callScope, StatementRangeReference callStatementRange)
    {
        return onCallImpl(this, callScope, callStatementRange);
    }

    //
    // IScope Functions
    //
    @property inout(BidmakeFile) tryAsFile() inout { return null; }
    @property IScope getParentScope() { return parentScope; }
    final TypedValue tryGetTypedValueImpl(string name)
    {
        assert(0, format("not implemented Interface.tryGetTypedValueImpl '%s'", name));
    }
    final void addInclude(BidmakeFile include)      { assert(0, "not implemented or not supported"); }
    final void addImport(BidmakeFile import_)       { assert(0, "not implemented or not supported"); }
    final void addDefine(Define define)             { assert(0, "not implemented or not supported"); }
    final void addInterface(Interface interface_)   { assert(0, "not implemented or not supported"); }
    final void addContractor(Contractor contractor) { assert(0, "not implemented or not supported"); }
    final void addContract(Contract contract)       { assert(0, "not implemented or not supported"); }
    final void addEnum(Enum enum_)                  { assert(0, "not implemented or not supported"); }

    //
    abstract InterfaceField getInlineField(size_t index);

    abstract @property size_t inlineFieldCount() const;
    abstract @property size_t fieldIDCount() const;
    abstract FieldID tryFindField(const(char)[] name);
    FieldID findField(T)(const(char)[] fieldName, lazy T errorContext)
    {
        FieldID id = tryFindField(fieldName);
        if(id == FieldID.null_)
        {
            writefln("%sError: interface \"%s\" does not have a field named \"%s\"", errorContext, name, fieldName);
            throw quit;
        }
        return id;
    }

    abstract InterfaceField getField(FieldID id);
    abstract const(Type) getFieldType(FieldID id);
    abstract TypedValue onCallImpl(Interface callInterface, IScope callScope, StatementRangeReference callStatementRange);
}

class ExplicitInterface : Interface
{
    size_t inlineCount;
    InterfaceField[] fields;
    this(string name, size_t inlineCount, InterfaceField[] fields, IScope parentScope)
    {
        super(name, parentScope);
        this.inlineCount = inlineCount;
        this.fields = fields;
    }
    override InterfaceField getInlineField(size_t index)
    {
        assert(index <= inlineCount);
        return fields[index];
    }
    override @property size_t inlineFieldCount() const { return inlineCount; }
    override @property size_t fieldIDCount() const { return fields.length; }
    override FieldID tryFindField(const(char)[] name)
    {
        foreach(i, field; fields)
        {
            if(field.name == name)
            {
                return FieldID(i);
            }
        }
        return FieldID.null_;
    }
    override InterfaceField getField(FieldID id)
    {
        return fields[id.index];
    }
    override const(Type) getFieldType(FieldID id)
    {
        return fields[id.index].type;
    }
    override TypedValue onCallImpl(Interface callInterface, IScope callScope, StatementRangeReference callStatementRange)
    {
        auto statementInlines = callStatementRange.expressionsLeft[1..$];
        if(statementInlines.length > inlineCount)
        {
            // todo: this error message won't make alot of sense if this is a forward interface
            // todo: support optional inline values at the end
            writefln("Error: the \"%s\" interface can accept %s inline values but got %s",
                callInterface.name, inlineCount, statementInlines.length);
            throw quit;
        }

        auto contractFields = new ContractField[callInterface.fieldIDCount];
        {
            size_t inlineIndex = 0;
            for(; inlineIndex < statementInlines.length; inlineIndex++)
            {
                auto error = fields[inlineIndex].type.interpretExpression(callScope, &contractFields[inlineIndex].value, statementInlines[inlineIndex]);
                if(error)
                {
                    writefln("Error: failed to parse \"%s\" as type \"%s\" for field \"%s\" because %s",
                        statementInlines[inlineIndex], fields[inlineIndex].type.processTypeName, fields[inlineIndex].name, error);
                    throw quit;
                }
                contractFields[inlineIndex].set = true;
            }
            if(inlineIndex < inlineCount)
            {
                writefln("%sError: optional inline values not implemented",
                    callScope.getFile().formatLocation(callStatementRange.statement.sourceStart));
                throw quit;
            }
        }
        foreach(blockStatement; callStatementRange.block)
        {
            auto firstSymbol = blockStatement.frontExpressionAsSymbol();
            //writefln("[DEBUG] processing '%s'", firstSymbol);

            // try analyzing it as a builtin statement first
            {
                auto result = tryAnalyzeBuiltin(callScope, firstSymbol, blockStatement.range(1));
                if(!result.isNull)
                {
                    continue;
                }
            }

            auto fieldID = tryFindField(firstSymbol);
            if(fieldID == FieldID.null_)
            {
                writefln("Error: interface \"%s\" does not have a property named \"%s\"", callInterface.name, firstSymbol);
                throw quit;
            }
            auto fieldType = getFieldType(fieldID);

            auto error = fieldType.interpretStatement(callScope, &contractFields[fieldID.index].value, blockStatement.range(1));
            if(error)
            {
                writefln("%sError: failed to process field \"%s\" as type \"%s\" because %s",
                   callScope.getFile().formatLocation(firstSymbol), firstSymbol, fieldType.processTypeName, error);
                throw quit;
            }
            contractFields[fieldID.index].set = true;
        }
        auto contract = new Contract(callInterface, contractFields, callScope);

        // set default values
        foreach(i; 0..contractFields.length)
        {
            auto interfaceField = getField(FieldID(i));
            if(!contractFields[i].set)
            {
                if(interfaceField.hasDefault)
                {
                    assert(!interfaceField.required, "codebug: interface field is required and has default?");
                    //writefln("[DEBUG] setting default value!");
                    auto error = interfaceField.type.interpretStatement(
                        contract.contractInterfaceScope(), &contractFields[i].value, interfaceField.default_.range(1));
                    if(error)
                    {
                        writefln("%sError: failed to process default value \"%s\" for field \"%s\" as type \"%s\" because %s",
                        callScope.getFile().formatLocation(interfaceField.default_.sourceStart),
                            interfaceField.name, interfaceField.type.processTypeName, error);
                        throw quit;
                    }
                }
                else if(interfaceField.required)
                {
                    writefln("%sError: required field '%s' is not set",
                        callScope.getFile().formatLocation(callStatementRange.sourceStart),
                        interfaceField.name);
                    throw quit;
                }
            }
        }

        callScope.addContract(contract);
        return contract.asTypedValue;
    }
}
class ForwardInterface : Interface
{
    Interface forwardInterface;
    this(string name, Interface forwardInterface, IScope parentScope)
    {
        super(name, parentScope);
        this.forwardInterface = forwardInterface;
    }
    override InterfaceField getInlineField(size_t index)
    {
        assert(0, "not implemented");
    }
    override @property size_t inlineFieldCount() const { assert(0, "forward interface inlineFieldCount not implemented"); }
    override @property size_t fieldIDCount() const
    {
        assert(0, "forward interface fieldIDCount not implemented");
    }
    override FieldID tryFindField(const(char)[] name)
    {
        auto fieldID = forwardInterface.tryFindField(name);
        if(!fieldID.isNull)
        {
            return fieldID;
        }
        assert(0, "forward interface tryFindField not implemented");
    }
    override InterfaceField getField(FieldID id)
    {
        assert(0, "forward interface getField not implemented");
    }
    override const(Type) getFieldType(FieldID id)
    {
        assert(0, "forward interface getFieldType not implemented");
    }
    override TypedValue onCallImpl(Interface callInterface, IScope callScope, StatementRangeReference callStatementRange)
    {
        // todo: for now just call the original interface as is
        writefln("WARNING: forwardInterface onCallImpl not implemented");
        forwardInterface.onCallImpl(callInterface, callScope, callStatementRange);
        assert(0, "not implemented");
    }
}

class ContractorType : BidmakeObjectType
{
    __gshared static immutable instance = new immutable ContractorType();
    //
    // Type fields
    //
    @property override string shallowName() const { return "contractor"; }
    final override ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        if(type !is instance)
        {
            return ErrorString(format(
                "cannot convert object of type 'contractor' to type '%s'", type.shallowName));
        }
        outValue.bidmakeObject = this;
        return ErrorString.null_; // success
    }
}

enum ContractorResult
{
    success,
    errorStop,
    errorContinue,
}
struct BuiltinContractor
{
    ContractorResult function(Contractor contractor, BidmakeFile contractFile, Contract contract, string[] args) execute;
    @property final bool isSet() { return execute !is null; }
}

class Contractor : IBidmakeObject, IScope
{
    string name;
    BuiltinContractor builtin;
    Interface[] interfaces;
    string[] actions;
    IScope parentScope;
    this(string name, BuiltinContractor builtin, Interface[] interfaces, string[] actions, IScope parentScope)
    {
        this.name = name;
        this.builtin = builtin;
        this.interfaces = interfaces;
        this.actions = actions;
        this.parentScope = parentScope;
    }

    final bool supports(Contract contract, string action)
    {
        return ((action is null) || actions.equalContains(action)) &&
            interfaces.isContains(contract.interface_);
    }
    final ContractorResult execute(BidmakeFile contractFile, Contract contract, string[] args)
    {
        if(builtin.isSet)
        {
            return builtin.execute(this, contractFile, contract, args);
        }
        else
        {
            writefln("Error: non-builtin contractors not implemented");
            return ContractorResult.errorStop;
        }
    }

    //
    // IBidmakeObject methods
    //
    @property const(Type) getType() const { return ContractorType.instance; }
    @property Value asValue() { return Value(this); }
    final inout(IScope) tryAsScope() inout { return this; }
    // TODO: maybe this should return an interface?
    inout(Interface) tryAsInterface() inout { return null; }
    inout(Type) tryAsType() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        assert(0, "not implemented");
    }
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        assert(0, "calling contractor directly not implemented");
    }

    //
    // IScope Functions
    //
    @property inout(BidmakeFile) tryAsFile() inout { return null; }
    @property IScope getParentScope() { return parentScope; }
    final TypedValue tryGetTypedValueImpl(string name) { assert(0, "not implemented"); }
    final void addInclude(BidmakeFile include)      { assert(0, "not implemented or not supported"); }
    final void addImport(BidmakeFile import_)       { assert(0, "not implemented or not supported"); }
    final void addDefine(Define define)             { assert(0, "not implemented or not supported"); }
    final void addInterface(Interface interface_)   { assert(0, "not implemented or not supported"); }
    final void addContractor(Contractor contractor) { assert(0, "not implemented or not supported"); }
    final void addContract(Contract contract)       { assert(0, "not implemented or not supported"); }
    final void addEnum(Enum enum_)                  { assert(0, "not implemented or not supported"); }
}

struct EnumValue
{
    size_t value;
    const(Enum) enumType;
    @property auto name() { return enumType.values[value]; }
    @property bool isNull() const { return enumType is null; }
}

union Value
{
    bool bool_;
    size_t sizet;
    string string_;
    Value[] list;
    IBidmakeObject bidmakeObject;
    this(bool bool_)     { this.bool_ = bool_; }
    this(size_t sizet)   { this.sizet = sizet; }
    this(string string_) { this.string_ = string_; }
    this(Value[] list)   { this.list = list; }
    this(IBidmakeObject bidmakeObject)
    {
        this.bidmakeObject = bidmakeObject;
    }
}
struct TypedValue
{
    @property static TypedValue null_() { return TypedValue(null); }
    @property static TypedValue void_() { return TypedValue(PrimitiveType.void_); }

    private Value value;
    private Rebindable!(const(Type)) type;
    this(Value value, const(Type) type)
    {
        this.value = value;
        this.type = type;
    }
    private this(const(Type) type)
    {
        this.type = type;
    }
    @property bool isNull() const { return type is null; }
    @property bool isVoid() const { return type is PrimitiveType.void_; }

    final inout(IScope) tryAsScope() inout
    {
        auto bidmakeObject = type.tryValueAsBidmakeObject(value);
        return bidmakeObject ? bidmakeObject.tryAsScope() : null;
    }
    final inout(BidmakeFile) tryAsFile() inout
    {
        auto scope_ = tryAsScope();
        return scope_ ? scope_.tryAsFile() : null;
    }
    final inout(Type) tryAsType() inout
    {
        auto bidmakeObject = type.tryValueAsBidmakeObject(value);
        return bidmakeObject ? bidmakeObject.tryAsType() : null;
    }
    final inout(Interface) tryAsInterface() inout
    {
        auto bidmakeObject = type.tryValueAsBidmakeObject(value);
        return bidmakeObject ? bidmakeObject.tryAsInterface() : null;
    }
    TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        auto bidmakeObject = type.tryValueAsBidmakeObject(value);
        if(bidmakeObject)
        {
            return bidmakeObject.onCall(callScope, statementRange);
        }
        assert(0, "onCall not implemented for type " ~ type.shallowName);
    }
    final ErrorString convertValueToType(Value* outValue, const(Type) targetType)
    {
        if(targetType.isAssignableFrom(type))
        {
            *outValue = value;
            return ErrorString.null_;
        }
        return ErrorString("value of type " ~ type.shallowName() ~
            " cannot be implicitly converted to type " ~ targetType.shallowName());
    }
}

/*
struct ContractTypedList(string ValueUnionField)
{
    Value[] list;
    @property auto length() { return list.length; }
    auto elementAt(size_t index)
    {
        mixin("return list[index]." ~ ValueUnionField ~ ";");
    }
    @property auto range()
    {
        struct Range
        {
            Value* next;
            Value* limit;
            @property size_t length() { return limit - next; }
            @property bool empty() { return next >= limit; }
            auto front() { mixin("return (*next)." ~ ValueUnionField ~ ";"); }
            void popFront() { next++; }
        }
        return Range(list.ptr, list.ptr + list.length);
    }
}
*/
struct ContractTypedList(PrimitiveTypeName primitiveTypeName)
{
    static assert(primitiveTypeName != PrimitiveTypeName.void_,
        "Cannot create a list of void typed elements");
    enum ValueUnionField = valueUnionField(primitiveTypeName);
    Value[] list;
    @property auto length() { return list.length; }
    auto elementAt(size_t index)
    {
        mixin("return list[index]." ~ ValueUnionField ~ ";");
    }
    @property auto range()
    {
        struct Range
        {
            Value* next;
            Value* limit;
            @property size_t length() { return limit - next; }
            @property bool empty() { return next >= limit; }
            auto front() { mixin("return (*next)." ~ ValueUnionField ~ ";"); }
            void popFront() { next++; }
        }
        return Range(list.ptr, list.ptr + list.length);
    }
}

class ContractType : Type
{
    __gshared static immutable instance = new immutable ContractType();
    this() immutable { }
    // IBidmakeObject fields
    @property const(Type) getType() const { return TypeType.instance; }
    @property Value asValue() { return Value(this); }
    final inout(IScope) tryAsScope() inout { assert(0, "not implemented"); }
    final inout(Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        assert(0, "not implemented");
    }
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        writefln("Error: you cannot call the contract type");
        throw quit;
    }
    // Type fields
    @property override string shallowName() const { return "contract"; }
    final override inout(PrimitiveType) tryAsPrimitive() inout { return null; }
    final override inout(ListType) tryAsListType() inout { return null; }
    @property final override const(Type) getProcessType() const { return getType(); }
    final override bool isAssignableFrom(const(Type) src) const
    {
        assert(0, "not implemented");
    }
    final override bool secondCheckIsAssignableTo(const(Type) dst) const
    {
        assert(0, "not implemented");
    }
    final override void valueFormatter(StringSink sink, const(Value)* field) const
    {
        assert(0, "not implemented");
    }
    final override inout(IBidmakeObject) tryValueAsBidmakeObject(inout(Value) value) const
    {
        return value.bidmakeObject;
    }
    final override ErrorString interpretString(IScope scope_, Value* outValue, string str) const
    {
        assert(0, "not implemented");
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

// This is the scope of the interface including the contract that is configuring the interface
// This is the scope used when evaluating default values for properties.
class ContractInterfaceScope : IScope
{
    Contract contract;
    this(Contract contract)
    {
        this.contract = contract;
    }
    //
    // IScope Functions
    //
    @property inout(BidmakeFile) tryAsFile() inout { return null; }
    @property IScope getParentScope() { return contract.interface_.parentScope; }
    final TypedValue tryGetTypedValueImpl(string name)
    {
        // special variable used to access the contract
        if(name == "contract")
        {
            return contract.asTypedValue;
        }
        return contract.tryGetTypedValue(name);
    }
    final void addInclude(BidmakeFile include)      { assert(0, "not implemented or not supported"); }
    final void addImport(BidmakeFile import_)       { assert(0, "not implemented or not supported"); }
    final void addDefine(Define define)             { assert(0, "not implemented or not supported"); }
    final void addInterface(Interface interface_)   { assert(0, "not implemented or not supported"); }
    final void addContractor(Contractor contractor) { assert(0, "not implemented or not supported"); }
    final void addContract(Contract contract)       { assert(0, "not implemented or not supported"); }
    final void addEnum(Enum enum_)                  { assert(0, "not implemented or not supported"); }
}

struct ContractField
{
    Value value;
    bool set;
}
class Contract : IBidmakeObject, IScope
{
    Interface interface_;
    ContractInterfaceScope cachedContractInterfaceScope;

    ContractField[] fields;
    IScope parentScope;
    this(Interface interface_, ContractField[] fields, IScope parentScope)
    {
        this.interface_ = interface_;
        this.fields = fields;
        this.parentScope = parentScope;
    }

    // TODO: need to return a new Scope type who's parent scope is the interface's parent
    //       scope, not the contract's parent scope.  For now this isn't needed since
    //       I haven't implemented looking up symbols in the parent scope.
    IScope contractInterfaceScope()
    {
        if(cachedContractInterfaceScope is null)
        {
            cachedContractInterfaceScope = new ContractInterfaceScope(this);
        }
        return cachedContractInterfaceScope;
    }
    auto lookupField(PrimitiveTypeName primitiveType)(string fieldName)
    {
        static if(
               primitiveType == PrimitiveTypeName.string_
            || primitiveType == PrimitiveTypeName.path
            || primitiveType == PrimitiveTypeName.dirpath
            || primitiveType == PrimitiveTypeName.filepath
            || primitiveType == PrimitiveTypeName.dirname
            || primitiveType == PrimitiveTypeName.filename
        ) {
            return lookupPrimitiveTypedStringField(fieldName, primitiveType);
        } else static if (primitiveType == PrimitiveTypeName.bool_) {
            auto fieldID = interface_.findField(fieldName, "");
            auto field = interface_.getField(fieldID);
            auto fieldPrimitiveType = field.type.tryAsPrimitive();
            if(fieldPrimitiveType is null || fieldPrimitiveType.name != primitiveType)
            {
                writefln("Error: expected field \"%s\" on interface \"%s\" to be type '%s' but is '%s'",
                    fieldName, interface_.name, primitiveType.get.typeNameString, field.type.shallowName);
                throw quit;
            }
            return mixin("fields[fieldID.index].value." ~ primitiveType.get.valueUnionField);
        } else static assert(0, "lookupField primitive type not implemented");
    }
    EnumValue lookupEnumField(string fieldName, Flag!"required" required)
    {
        auto fieldID = interface_.findField(fieldName, "");
        auto field = interface_.getField(fieldID);
        if(required)
        {
            if (!field.required)
            {
                writefln("Error: expected field '%s' to be required but it isn't",
                    fieldName);
                throw quit;
            }
        }
        auto asEnum = cast(Enum)field.type;
        if (asEnum is null)
        {
            writefln("Error: expected field '%s' to be an enum but its type is '%s'",
                fieldName, field.type.shallowName);
            throw quit;
        }
        if (!fields[fieldID.index].set)
        {
            assert(!required, "codebug: required field was not set");
            return EnumValue.init;
        }
        return EnumValue(fields[fieldID.index].value.sizet, asEnum);
    }
    private string lookupPrimitiveTypedStringField(string fieldName, PrimitiveTypeName expectedType)
    {
        auto fieldID = interface_.findField(fieldName, "");
        auto field = interface_.getField(fieldID);
        auto fieldPrimitiveType = field.type.tryAsPrimitive();
        if(fieldPrimitiveType is null || fieldPrimitiveType.name != expectedType)
        {
            writefln("Error: expected field \"%s\" on interface \"%s\" to be type '%s' but is '%s'",
                fieldName, interface_.name, expectedType, field.type.shallowName);
            throw quit;
        }
        return fields[fieldID.index].value.string_;
    }
    auto lookupListField(PrimitiveTypeName elementType)(string fieldName)
    {
        auto fieldID = interface_.findField(fieldName, "");
        auto field = interface_.getField(fieldID);

        auto fieldListType = field.type.tryAsListType();
        if(fieldListType is null)
        {
            writefln("Error: field \"%s\" on interface \"%s\" is not a list, it's type is \"%s\"",
                fieldName, interface_.name, field.type.shallowTypeName);
            throw quit;
        }
        auto fieldElementPrimitiveType = fieldListType.elementType.tryAsPrimitive();
        if(fieldElementPrimitiveType is null || fieldElementPrimitiveType.name != elementType)
        {
            writefln("Error: expected field \"%s\" on interface \"%s\" to be a list of '%s' but is a list of '%s'",
                fieldName, interface_.name, elementType, fieldListType.elementType.shallowTypeName);
            throw quit;
        }
        return ContractTypedList!elementType(fields[fieldID.index].value.list);
    }

    //
    // IBidmakeObject methods
    //
    @property const(Type) getType() const { return ContractType.instance; }
    @property Value asValue() { return Value(this); }
    final inout(IScope) tryAsScope() inout { return this; }
    inout(Interface) tryAsInterface() inout { return null; }
    inout(Type) tryAsType() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final ErrorString convertValueToType(IScope scope_, Value* outValue, const(Type) type)
    {
        if(type !is ContractType.instance)
        {
            assert(0, "not implemented");
        }
        outValue.bidmakeObject = this;
        return ErrorString.null_; // success
    }
    final TypedValue onCall(IScope callScope, StatementRangeReference statementRange)
    {
        writefln("Error: you cannot call a contract");
        throw quit;
    }

    //
    // IScope Functions
    //
    @property inout(BidmakeFile) tryAsFile() inout { return null; }
    @property IScope getParentScope() { return parentScope; }
    final TypedValue tryGetTypedValueImpl(string name)
    {
        auto fieldID = interface_.findField(name, "");
        auto field = interface_.getField(fieldID);
        return TypedValue(fields[fieldID.index].value, field.type);
    }
    final void addInclude(BidmakeFile include)      { assert(0, "not implemented or not supported"); }
    final void addImport(BidmakeFile import_)       { assert(0, "not implemented or not supported"); }
    final void addDefine(Define define)             { assert(0, "not implemented or not supported"); }
    final void addInterface(Interface interface_)   { assert(0, "not implemented or not supported"); }
    final void addContractor(Contractor contractor) { assert(0, "not implemented or not supported"); }
    final void addContract(Contract contract)       { assert(0, "not implemented or not supported"); }
    final void addEnum(Enum enum_)                  { assert(0, "not implemented or not supported"); }

    //
    //
    @property DelegateFormatter formatPretty()
    {
        return DelegateFormatter(&prettyFormatter);
    }
    private void prettyFormatter(StringSink sink)
    {
        formattedWrite(sink, "%s", interface_.name);
        foreach(i; 0..interface_.inlineFieldCount)
        {
            sink(" ");
            interface_.getInlineField(i).type.valueFormatter(sink, &fields[i].value);
        }
        sink("\n{\n");
        foreach(i; interface_.inlineFieldCount..fields.length)
        {
            auto field = interface_.getField(FieldID(i));
            sink("   ");
            sink(field.name);
            sink(" ");
            field.type.valueFormatter(sink, &fields[i].value);
            sink("\n");
        }
        sink("}\n");
    }
}

string expressionAsSymbol(ref Statement statement, size_t index)
{
    if(index >= statement.expressionCount)
    {
        // TODO: better error message
        writefln("Error: expected a symbol but got ", (statement.block is null) ? ";" : " a '{ block }'");
        throw quit;
    }
    if(statement.expressionAt(index).type != ExpressionType.symbol)
    {
        // TODO: better error message
        writefln("Error: expected a symbol but got \"%s\"", statement.expressionAt(index).type);
        throw quit;
    }
    // sanity check
    assert(statement.expressionAt(index).source is statement.expressionAt(index).string_);
    return statement.expressionAt(index).source;
}
string expressionAsString(ref Statement statement, size_t index)
{
    if(index >= statement.expressionCount)
    {
        // TODO: better error message
        writefln("Error: expected a string but got ", (statement.block is null) ? ";" : " a '{ block }'");
        throw quit;
    }
    if(statement.expressionAt(index).type != ExpressionType.string_)
    {
        // TODO: better error message
        writefln("Error: expected a string but got \"%s\"", statement.expressionAt(index).type);
        throw quit;
    }
    return statement.expressionAt(index).string_;
}
string frontExpressionAsSymbol(ref Statement statement)
{
    return expressionAsSymbol(statement, 0);
}

string expressionAsSymbol(StatementRangeReference statementRange, size_t index)
{
    auto fullStatementIndex = statementRange.next + index;
    if(fullStatementIndex >= statementRange.statement.expressionCount)
    {
        // TODO: better error message
        writefln("Error: expected a symbol but got ",
            (statementRange.statement.block is null) ? ";" : " a '{ block }'");
        throw quit;
    }
    if(statementRange.statement.expressionAt(fullStatementIndex).type != ExpressionType.symbol)
    {
        // TODO: better error message
        writefln("Error: expected a symbol but got \"%s\"", statementRange.statement.expressionAt(fullStatementIndex).type);
        throw quit;
    }
    // sanity check
    assert(statementRange.statement.expressionAt(fullStatementIndex).source is statementRange.statement.expressionAt(fullStatementIndex).string_);
    return statementRange.statement.expressionAt(fullStatementIndex).source;
}
string expressionAsString(StatementRangeReference statementRange, size_t index)
{
    auto fullStatementIndex = statementRange.next + index;
    if(fullStatementIndex >= statementRange.statement.expressionCount)
    {
        // TODO: better error message
        writefln("Error: expected a string but got ",
            (statementRange.statement.block is null) ? ";" : " a '{ block }'");
        throw quit;
    }
    if(statementRange.statement.expressionAt(fullStatementIndex).type != ExpressionType.string_)
    {
        // TODO: better error message
        writefln("Error: expected a string but got \"%s\"", statementRange.statement.expressionAt(fullStatementIndex).type);
        throw quit;
    }
    return statementRange.statement.expressionAt(fullStatementIndex).string_;
}
string frontExpressionAsSymbol(StatementRangeReference statementRange)
{
    return expressionAsSymbol(statementRange, 0);
}

auto ref assertMinExpressionCount(ref Statement statement, size_t minExpressionCount)
{
    if(statement.expressionCount < minExpressionCount)
    {
        // TODO: better error message
        writefln("Error: the statement must have at least %s expression(s) but it has %s",
           minExpressionCount, statement.expressionCount);
        throw quit;
    }
    return statement;
}
auto assertMinExpressionCount(StatementRangeReference statementRange, size_t minExpressionLeftCount)
{
    auto minExpressionTotalCount = minExpressionLeftCount + statementRange.next;
    if(statementRange.statement.expressionCount < minExpressionTotalCount)
    {
        // TODO: better error message
        writefln("Error: the statement must have at least %s expression(s) but it has %s",
           minExpressionTotalCount, statementRange.statement.expressionCount);
        throw quit;
    }
    return statementRange;
}

auto ref assertExpressionCount(ref Statement statement, size_t expectedExpressionCount)
{
    if(statement.expressionCount != expectedExpressionCount)
    {
        // TODO: better error message
        writefln("Error: the statement must have %s expression(s) but it has %s",
           expectedExpressionCount, statement.expressionCount);
        throw quit;
    }
    return statement;
}
auto assertExpressionCount(StatementRangeReference statementRange, size_t expectedExpressionsLeftCount)
{
    auto totalExpectedCount = expectedExpressionsLeftCount + statementRange.next;
    if(statementRange.statement.expressionCount != totalExpectedCount)
    {
        // TODO: better error message
        writefln("Error: the statement must have %s expression(s) but it has %s",
           totalExpectedCount, statementRange.statement.expressionCount);
        throw quit;
    }
    return statementRange;
}
auto ref assertNoBlock(ref Statement statement, IScope scope_)
{
    if(statement.block !is null)
    {
        // TODO: better error message
        writefln("%sError: unexpected statement block", scope_.getFile().formatLocation(statement.sourceStart));
        throw quit;
    }
    return statement;
}
auto assertNoBlock(StatementRangeReference statementRange, IScope scope_)
{
    if(statementRange.statement.block !is null)
    {
        // TODO: better error message
        writefln("%sError: unexpected statement block", scope_.getFile().formatLocation(statementRange.sourceStart));
        throw quit;
    }
    return statementRange;
}
auto ref assertHasBlock(ref Statement statement)
{
    if(statement.block is null)
    {
        // TODO: better error message
        writefln("Error: need statement block");
        throw quit;
    }
    return statement;
}
auto assertHasBlock(StatementRangeReference statementRange)
{
    if(statementRange.statement.block is null)
    {
        // TODO: better error message
        writefln("Error: need statement block");
        throw quit;
    }
    return statementRange;
}

/*
struct QualifyingLookup
{
    IScope mostInnerScope;
    string mostUnqualifiedSymbol;
    auto tryLookup()
    {
        for(;;)
        {
            auto peeled = peelQualifiedName(mostUnqualifiedSymbol);
            if(peeled.rest is null)
            {
                break;
            }
            auto newScope = mostInnerScope.tryGetScope(peeled.nextName);
            if(newScope is null)
            {
                return null;
            }
            mostInnerScope = newScope;
            mostUnqualifiedSymbol = peeled.rest;
        }

        return mostInnerScope.tryGet(mostUnqualifiedSymbol);
    }
}
*/


BidmakeFile analyze(BidmakeFile bidmakeFile)
{
    if(bidmakeFile.state >= BidmakeFileState.analyzed)
    {
        return bidmakeFile.redirect;
    }
    if(bidmakeFile.state != BidmakeFileState.parsed)
    {
        writefln("Error: cannot analyze a bidmake file before it is parsed");
        throw quit;
    }
    scope(exit)
    {
        assert(bidmakeFile.state == BidmakeFileState.parsed);
        bidmakeFile.state = BidmakeFileState.analyzed;
    }

    foreach(statement; bidmakeFile.block)
    {
        analyzeStatement(bidmakeFile, statement.range(0));
    }

    if(bidmakeFile.redirect)
    {
        // TODO: throw if anything was included that is not compatible with redirect
    }
    else
    {
        bidmakeFile.redirect = bidmakeFile;
    }
    return bidmakeFile.redirect;
}

// Note: must check returnValue.isNull after calling, which means the satement
//       was not handled.
TypedValue tryAnalyzeBuiltin(IScope scope_, string operation, StatementRangeReference statement)
{
    if(operation == "import")
    {
        statement.assertExpressionCount(1).assertNoBlock(scope_);
        return importLibrary(scope_, statement.frontExpressionAsSymbol());
    }
    if(operation == "include")
    {
        statement.assertExpressionCount(1).assertNoBlock(scope_);
        Value value = void;
        auto error = defaultExpressionToValueEvaluator(statement.expressionAt(0),
            scope_, &value, PrimitiveType.string_);
        if(error)
        {
            writefln("%sError: failed to evaluate 'include' argument as string: " ~ error.error);
            throw quit;
        }
        return addInclude(scope_, value.string_);
    }
    if(operation == "redirect")
    {
        auto asFile = scope_.tryAsFile();
        if(asFile is null)
        {
            writefln("%sError: the 'redirect' command may only appear at global scope",
                scope_.getFile().formatLocation(operation));
            throw quit;
        }
        if(asFile.redirect)
        {
            writefln("Error: a file cannot contain multiple redirects");
            throw quit;
        }
        statement.assertExpressionCount(1).assertNoBlock(scope_);
        asFile.redirect = loadRedirect(asFile, statement.frontExpressionAsSymbol());
        return asFile.redirect.asTypedValue;
    }
    if(operation == "enum")
    {
        statement.assertExpressionCount(1).assertHasBlock();
        return addEnumDefinition(scope_, statement.frontExpressionAsSymbol(), statement.block);
    }
    if(operation == "define")
    {
        statement.assertExpressionCount(3).assertNoBlock(scope_);
        return addDefine(scope_, statement.expressionAsSymbol(0), statement.expressionAsSymbol(1), statement.expressionAt(2));
    }
    if(operation == "let")
    {
        statement.assertMinExpressionCount(1);
        return addLet(scope_, statement.expressionAsSymbol(0), statement.range(1));
    }
    if(operation == "interface")
    {
        statement.assertExpressionCount(1).assertHasBlock();
        return addInterfaceDefinition(scope_, statement.frontExpressionAsSymbol(), statement.block);
    }
    if(operation == "forwardInterface")
    {
        statement.assertExpressionCount(2).assertHasBlock();
        return addForwardInterfaceDefinition(scope_, statement.expressionAsSymbol(0), statement.expressionAsSymbol(1), statement.block);
    }
    if(operation == "contractor")
    {
        statement.assertExpressionCount(1).assertHasBlock();
        return addContractor(scope_, statement.expressionAsSymbol(0), statement.block);
    }
    return TypedValue.null_;
}

TypedValue analyzeStatement(IScope scope_, StatementRangeReference statement)
{
    auto operation = statement.frontExpressionAsSymbol();
    TypedValue returnValue = tryAnalyzeBuiltin(scope_, operation, statement.range(1));
    if(returnValue.isNull)
    {
        return lookupQualifiedSymbol(scope_, operation).onCall(scope_, statement);
    }
    else
    {
        return returnValue;
    }
}

TypedValue importLibrary(IScope scope_, string importName)
{
    {
        auto existing = scope_.tryGetTypedValue(importName);
        if(!existing.isNull)
        {
            auto existingAsFile = existing.tryAsFile();
            if(existingAsFile)
            {
                return existing;
            }
            writefln("%sError: cannot import '%s' because that symbol is already defined with type %s",
                scope_.getFile().formatLocation(importName), importName, existing.type.shallowName);
            throw quit;
        }
    }
    /*
    auto existing = scope_.tryGetImport(importName);
    if(existing)
    {
        return existing;
    }
    */
    /*
    foreach(import_; bidmakeFile.imports)
    {
        if(import_.importName == importName)
        {
            writefln("library \"%s\" has already been imported");
            return import_.asTypedValue;
        }
    }
    */

    auto currentFile = scope_.getFile();

    // find the library
    // 1. search in the same directory
    // 2. searcn in the global repository
    auto importNameWithExtension = importName ~ ".bidmake";
    string foundLibraryFilename = null;
    if(foundLibraryFilename is null)
    {
        auto libraryFilenameInSameDirectory = buildPath(currentFile.dir, importNameWithExtension);
        if(exists(libraryFilenameInSameDirectory))
        {
            foundLibraryFilename = libraryFilenameInSameDirectory;
        }
    }
    if(foundLibraryFilename is null)
    {
        auto libraryFilenameInRepoPath = buildPath(globalRepoPath, importNameWithExtension);
        if(exists(libraryFilenameInRepoPath))
        {
            foundLibraryFilename = libraryFilenameInRepoPath;
        }
    }
    if(foundLibraryFilename is null)
    {
        writefln("import \"%s\" is not found in any of the following directories:", importName);
        writefln("[0] %s", currentFile.dir.formatDir);
        writefln("[1] %s", globalRepoPath.formatDir);
        throw quit;
    }

    //writefln("[DEBUG] found import \"%s\" at \"%s\"", importName, foundLibraryFilename);
    auto importFile = loadBidmakeFile(foundLibraryFilename, Yes.parse);
    // note: analyzed may or may not be the same as importFile.  if the importFile
    //       has a redirect, it will not be the same
    auto analyzed = analyze(importFile);
    scope_.addImport(analyzed);
    return analyzed.asTypedValue;
}
TypedValue addInclude(IScope scope_, string includePath)
{
    auto includeFullPath = buildPath(scope_.getFile().dir, includePath);
    if(!exists(includeFullPath))
    {
        writefln("%sError: include \"%s\" does not exist at \"%s\"",
            scope_.getFile().formatLocation(includePath), includePath, includeFullPath);
        throw quit;
    }
    if(isDir(includeFullPath))
    {
        foreach(entry; dirEntries(includeFullPath, "*.bidmake", SpanMode.shallow))
        {
            auto includeFile = loadBidmakeFile(entry.name, Yes.parse);
            auto analyzed = analyze(includeFile);
            scope_.addInclude(analyzed);
        }
    }
    else
    {
        auto includeFile = loadBidmakeFile(includeFullPath, Yes.parse);
        auto analyzed = analyze(includeFile);
        scope_.addInclude(analyzed);
    }
    return TypedValue.void_; // for now, include doesn't return anything
}
BidmakeFile loadRedirect(BidmakeFile bidmakeFile, string redirectPathfile)
{
    auto correctedPathfile = buildNormalizedPath(bidmakeFile.dir, redirectPathfile);
    // TODO: make sure the redirect is different than the original file?
    if(!exists(correctedPathfile))
    {
        writefln("Error: redirected file \"%s\" does not exist", correctedPathfile);
        throw quit;
    }
    return analyze(loadBidmakeFile(correctedPathfile, Yes.parse));
}
TypedValue addEnumDefinition(IScope scope_, string enumName, Statement[] block)
{
    assertNoSymbol(scope_, enumName, "enum type");
    auto values = new string[block.length];
    foreach(i, statement; block)
    {
        statement.assertNoBlock(scope_);
        if(statement.expressionCount != 1)
        {
            writefln("Error: all Enum statements must be 1 expression, but this one has %s", statement.expressionCount);
            throw quit;
        }
        // todo: assert expression type
        values[i] = statement.expressionAsSymbol(0);
    }
    auto enumDefinition = new Enum(enumName, values, scope_);
    scope_.addEnum(enumDefinition);
    return enumDefinition.asTypedValue;
}
TypedValue addDefine(IScope scope_, string typeName, string symbol, Expression valueExpression)
{
    auto type = lookupType(scope_, typeName);
    assertNoSymbol(scope_, symbol, "define variable");
    Value value;
    {
        auto error = type.interpretExpression(scope_, &value, valueExpression);
        if(error)
        {
            writefln("Error: invalid expression \"%s\" for type \"%s\": %s", valueExpression.source,
                typeName, error);
            throw quit;
        }
    }
    auto define = new Define(value, type, symbol);
    scope_.addDefine(define);
    return define.asTypedValue;
}
TypedValue addLet(IScope scope_, string symbol, StatementRangeReference statementRest)
{
    assertNoSymbol(scope_, symbol, "variable");

    auto result = analyzeStatement(scope_, statementRest);
    if(result.isVoid)
    {
        writefln("%sError: the 'let' statement value evaluated to void",
            scope_.getFile().formatLocation(symbol));
        throw quit;
    }
    auto define = new Define(result.value, result.type, symbol);
    scope_.addDefine(define);
    return define.asTypedValue;
}
TypedValue addInterfaceDefinition(IScope scope_, string interfaceName, Statement[] block)
{
    assertNoSymbol(scope_, interfaceName, "interface");
    auto fieldBuilder = appender!(InterfaceField[]);
    size_t statementIndex = 0;
    // parse inline statements first
    for(; statementIndex < block.length; statementIndex++)
    {
        auto statement = &block[statementIndex];
        if(statement.expressionCount == 0)
        {
            break;
        }
        if(statement.expressionAt(0).source == "inline")
        {
            fieldBuilder.put(processInterfaceTypeField(scope_, statement.range(1)));
        }
        else
        {
            break;
        }
    }
    size_t inlinePropertyCount = statementIndex;

  PROPERTY_LOOP:
    for(; statementIndex < block.length; statementIndex++)
    {
        auto statement = &block[statementIndex];
        auto operation = (*statement).frontExpressionAsSymbol();
        if(operation == "action")
        {
            assert(0, "action on interfaces not implemented, not sure if it makes sense");
        }
        else if(operation == "inline")
        {
            writefln("Error: inline statements must appear at the beginning of the interface");
            throw quit;
        }
        else if(operation == "list")
        {
            auto field = processInterfaceTypeField(scope_, statement.range(1));
            field.type = new ListType(field.type);
            fieldBuilder.put(field);
        }
        else if(operation == "required")
        {
            auto field = processInterfaceTypeField(scope_, statement.range(1));
            field.required = true;
            fieldBuilder.put(field);
        }
        else
        {
            Rebindable!(const(Type)) type = null;
            if(type is null)
            {
                foreach(primitiveType; PrimitiveType.table)
                {
                    if(operation == primitiveType.typeNameString)
                    {
                        type = primitiveType;
                        break;
                    }
                }
            }
            if(type is null)
            {
                auto obj = lookupQualifiedSymbol(scope_, operation);
                type = obj.tryAsType();
                if(type is null)
                {
                    writefln("Error: expected a type but got \"%s\"", obj.type.shallowName);
                    throw quit;
                }
            }
            (*statement).assertExpressionCount(2);
            auto newField = InterfaceField(type, (*statement).expressionAsSymbol(1));
            processFieldModifiers(scope_, &newField, statement.block);
            fieldBuilder.put(newField);
        }
    }
    auto interface_ = new ExplicitInterface(interfaceName, inlinePropertyCount, fieldBuilder.data, scope_);
    scope_.addInterface(interface_);
    return interface_.asTypedValue;
}
void processFieldModifiers(IScope scope_, InterfaceField* field, Statement[] block)
{
    foreach(fieldStatement; block)
    {
        auto fieldModifier = fieldStatement.frontExpressionAsSymbol();
        if(fieldModifier == "default")
        {
            if(field.hasDefault)
            {
                writefln("%sError: a field cannot have multiple default values", scope_.getFile().formatLocation(fieldModifier));
                throw quit;
            }
            field.default_ = fieldStatement;
            field.hasDefault = true;
        }
        else
        {
            writefln("%sError: unknown field modifier \"%s\"", scope_.getFile().formatLocation(fieldModifier), fieldModifier);
            throw quit;
        }
    }
}

InterfaceField processInterfaceTypeField(IScope scope_, StatementRangeReference statement)
{
    if(statement.empty)
    {
        writefln("Error: expected a type but got nothing (originalProperty=offset=%s, %s)", statement.next, *statement.statement);
        throw quit;
    }

    string typeString;
    {
        auto expression = statement.front();
        statement.popFront();
        if(expression.type != ExpressionType.symbol)
        {
            writefln("Error: expected a type symbol for the field type but got '%s'", expression.type);
            throw quit;
        }
        // sanity check
        assert(expression.source == expression.string_);
        typeString = expression.source;
    }

    auto type = lookupType(scope_, typeString);
    if(statement.empty)
    {
        writefln("Error: expected a name but got nothing");
        throw quit;
    }

    string fieldName;
    {
        auto expression = statement.front();
        statement.popFront();
        if(!statement.empty)
        {
            writefln("Error: too many values for interface field");
            throw quit;
        }

        if(expression.type != ExpressionType.symbol)
        {
            writefln("Error: expected a symbol for the field name but got '%s'", expression.type);
            throw quit;
        }
        // sanity check
        assert(expression.source == expression.string_);
        fieldName = expression.source;
    }
    return InterfaceField(rebindable(type), fieldName);
}

TypedValue addForwardInterfaceDefinition(IScope scope_, string interfaceName, string forwardInterfaceName, Statement[] block)
{
    assertNoSymbol(scope_, interfaceName, "forward interface");
    auto forwardInterfaceObject = lookupQualifiedSymbol(scope_, forwardInterfaceName);
    auto forwardInterface = forwardInterfaceObject.tryAsInterface();
    if(forwardInterface is null)
    {
        writefln("Error: cannot create a forwardInterface to \"%s\" because it's type is \"%s\"",
            forwardInterfaceName, forwardInterfaceObject.type.shallowName);
        throw quit;
    }
    // todo: process the forward interface
    auto interface_ = new ForwardInterface(interfaceName, forwardInterface, scope_);
    scope_.addInterface(interface_);
    return interface_.asTypedValue;
}

TypedValue addContractor(IScope scope_, string contractorName, Statement[] block)
{
    BuiltinContractor builtin;
    Interface[] interfaces;
    string[] actions;
    for(size_t statementIndex = 0; statementIndex < block.length; statementIndex++)
    {
        auto statement = &block[statementIndex];
        auto operation = (*statement).frontExpressionAsSymbol();
        if(operation == "implement")
        {
            (*statement).assertExpressionCount(2).assertNoBlock(scope_);
            auto obj = lookupQualifiedSymbol(scope_, (*statement).expressionAsSymbol(1));
            auto objAsInterface = obj.tryAsInterface();
            if(!objAsInterface)
            {
                writefln("%sError: expected an interface but the type is \"%s\"",
                    scope_.getFile().formatLocation((*statement).expressionAsSymbol(1)), obj.type.shallowName);
                throw quit;
            }
            if(isContains(interfaces, objAsInterface))
            {
                writefln("Error: interface \"%s\" was give more than once", objAsInterface.name);
                throw quit;
            }
            interfaces ~= objAsInterface;
        }
        else if(operation == "action")
        {
            (*statement).assertExpressionCount(2).assertNoBlock(scope_);
            actions ~= (*statement).expressionAsSymbol(1);
        }
        else if(operation == "builtin")
        {
            if(builtin.isSet)
            {
                writefln("Error: builtin was specified more than once");
                throw quit;
            }
            if(contractorName == "dmd")
            {
                builtin = BuiltinContractor(&dmdExecute);
            }
            else if(contractorName == "git")
            {
                builtin = BuiltinContractor(&gitExecute);
            }
            else
            {
                writefln("%sError: contractor \"%s\" is 'builtin' but no implmentation exists",
                    scope_.getFile().formatLocation(operation), contractorName);
                throw quit;
            }
        }
        else
        {
            writefln("%sError: unknown contractor statement \"%s\"", scope_.getFile().formatLocation(operation), operation);
            throw quit;
        }
    }
    auto contractor = new Contractor(contractorName, builtin, interfaces, actions, scope_);
    scope_.addContractor(contractor);
    return contractor.asTypedValue;
}
