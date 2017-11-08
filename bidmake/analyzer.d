module bidmake.analyzer;

import std.stdio;
import std.file   : exists, isDir, dirEntries, SpanMode;
import std.path   : baseName, stripExtension, buildPath, buildNormalizedPath;
import std.format : format, formattedWrite;
import std.conv   : to;
import std.traits : isDynamicArray, hasUDA, getUDAs, isArray;
import std.array  : Appender, appender;
import std.range  : ElementType;
import std.algorithm: count;
import std.typecons : Flag, Yes, No;

import util : unconst, immutable_zstring, quit, equalContains,  isContains,StringSink, DelegateFormatter, formatDir,
              PeeledName, peelQualifiedName, containsPathSeperator, readFile, DirAndFile;
import bidmake.parser : ExpressionType, Expression, BidmakeStatement, BidmakeStatementRangeReference, parseBidmake;
import bidmake.builtincontractors;
import bidmake.builtinfunctions : interpretCall;

__gshared string globalRepoPath;

interface IBidmakeObject
{
    @property string shallowTypeName() const;
    @property string processTypeName() const;
    //Type type();
    inout(Interface) tryAsInterface() inout;
    inout(Type) tryAsType() inout;
    inout(Define) tryAsDefine() inout;
    string interpretAsValue(IScope scope_, Value* outValue, Type type);
    string interpretAsPrimitiveValue(IScope scope_, Value* outValue, PrimitiveType type);
    void onCall(IScope callScope, BidmakeStatement statement);
}

abstract class Type : IBidmakeObject
{
    inout(Type) tryAsType() inout { return this; }
    abstract inout(PrimitiveType) tryAsPrimitive() inout;
    abstract inout(ListType) tryAsListType() inout;

    abstract bool isAssignableFrom(const(Type) src) const;
    // Note: this function is only called if the dst type does not
    //       know about the src type.  So this function will always be called
    //       inside dst.isAssignableFrom(this).
    protected abstract bool secondCheckIsAssignableTo(const(Type) dst) const;

    auto formatField(Value* field)
    {
        static struct Formatter
        {
            Type type;
            Value *field;
            void toString(StringSink sink) const
            {
                type.fieldFormatter(sink, field);
            }
        }
        return Formatter(this, field);
    }

    // TODO: add an isValueSet method
    abstract void fieldFormatter(StringSink sink, const(Value)* field) const;
    // returns: error message on error
    abstract string interpretString(IScope scope_, Value* outValue, string str);
    // returns: error message on error
    abstract string interpretExpression(IScope scope_, Value* outValue, Expression expression);
    // returns: error message on error
    abstract string tryProcessProperty(IScope scope_, Value* outValue, BidmakeStatementRangeReference statement);
}

enum PrimitiveTypeName
{
    string_,  // just a generic string
    path,     // a filesystem path, could be a directory or a file
    dirpath,  // a filesystem path that represents a directory
    filepath, // a filesystem path that represents a file
    dirname,  // a name that represents a directory.  it does not contain a path.
    filename, // a name that represesnts a file. it does not contain a path.
}
@property string contractFieldMember(PrimitiveTypeName typeName)
{
    return PrimitiveType.staticTypes[typeName].contractFieldMember;
}
class PrimitiveType : Type
{
    static immutable(PrimitiveType) get(PrimitiveTypeName name)
    {
        auto entry = staticTypes[name];
        assert(entry);
        return entry;
    }
    static __gshared immutable PrimitiveType[] staticTypes = [
        PrimitiveTypeName.string_  : new immutable PrimitiveType(PrimitiveTypeName.string_, "string", "string_"),
        PrimitiveTypeName.path     : new immutable PrimitiveType(PrimitiveTypeName.path, "path", "string_"),
        PrimitiveTypeName.dirpath  : new immutable PrimitiveType(PrimitiveTypeName.dirpath, "dirpath", "string_"),
        PrimitiveTypeName.filepath : new immutable PrimitiveType(PrimitiveTypeName.filepath, "filepath", "string_"),
        PrimitiveTypeName.dirname  : new immutable PrimitiveType(PrimitiveTypeName.dirname, "dirname", "string_"),
        PrimitiveTypeName.filename : new immutable PrimitiveType(PrimitiveTypeName.filename, "filename", "string_"),
    ];
    auto string_() { return staticTypes[PrimitiveTypeName.string_].unconst; }

    PrimitiveTypeName name;
    string typeNameString;
    string contractFieldMember;
    private this(PrimitiveTypeName name, string typeNameString, string contractFieldMember) immutable
    {
        this.name = name;
        this.typeNameString = typeNameString;
        this.contractFieldMember = contractFieldMember;
    }

    // IBidmakeObject fields
    @property final string shallowTypeName() const { return typeNameString; }
    @property final string processTypeName() const { return typeNameString; }
    final inout(Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final string interpretAsValue(IScope scope_, Value* outValue, Type type)
    {
        assert(0, "not implemented");
    }
    final string interpretAsPrimitiveValue(IScope scope_, Value* outValue, PrimitiveType type)
    {
        assert(0, "not implemented");
    }
    final void onCall(IScope callScope, BidmakeStatement statement)
    {
        writefln("Error: you cannot call an object of type \"%s\"", typeNameString);
        throw quit;
    }

    // Type fields
    final override inout(PrimitiveType) tryAsPrimitive() inout { return this; }
    final override inout(ListType) tryAsListType() inout { return null; }
    final override bool isAssignableFrom(const(Type) src) const
    {
        auto srcAsPrimitiveType = src.tryAsPrimitive();
        if(srcAsPrimitiveType is null)
        {
            return src.secondCheckIsAssignableTo(this);
        }
        final switch(name)
        {
            case PrimitiveTypeName.string_:
                return
                       srcAsPrimitiveType.name == PrimitiveTypeName.string_
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
                return srcAsPrimitiveType.name == PrimitiveTypeName.dirpath;
            case PrimitiveTypeName.filepath:
                return srcAsPrimitiveType.name == PrimitiveTypeName.filepath;
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
    final override void fieldFormatter(StringSink sink, const(Value)* field) const
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
        else assert(0, "fieldFormatter for type " ~ name.to!string ~ " is not implemented");
    }
    final override string interpretString(IScope scope_, Value* outValue, string str)
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
                return "cannot contain path seperators";
            }
            outValue.string_ = str;
            return null;
        }
        return "interpretString for primitive type '" ~ name.to!string ~ "' is not implemented";
    }
    final override string interpretExpression(IScope scope_, Value* outValue, Expression expression)
    {
        return defaultExpressionToValueEvaluator(expression, scope_, outValue, this);
    }
    final override string tryProcessProperty(IScope scope_, Value* outValue, BidmakeStatementRangeReference statement)
    {
        statement.assertNoBlock.assertRemainingValueLength(1);
        return interpretExpression(scope_, outValue, statement.front);
    }
}
class Enum : Type
{
    string name;
    string[] values;
    this(string name, string[] values)
    {
        this.name = name;
        this.values = values;
    }

    // IBidmakeObject fields
    @property final string shallowTypeName() const { return name; }
    @property final string processTypeName() const { return name; }
    final inout(Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final string interpretAsValue(IScope scope_, Value* outValue, Type type)
    {
        // TODO: assign the Enum type itself to outValue
        assert(0, "not implemented");
    }
    final string interpretAsPrimitiveValue(IScope scope_, Value* outValue, PrimitiveType type)
    {
        return "the Enum type " ~ name ~ " itself cannot be interpreted as a value of primitive type " ~ type.name.to!string;
    }
    final void onCall(IScope callScope, BidmakeStatement statement)
    {
        writefln("Error: you cannot call an enum");
        throw quit;
    }

    // Type fields
    final override inout(PrimitiveType) tryAsPrimitive() inout { return null; }
    final override inout(ListType) tryAsListType() inout { return null; }
    final override bool isAssignableFrom(const(Type) src) const
    {
        return this is src;
    }
    final override bool secondCheckIsAssignableTo(const(Type) dst) const
    {
        assert(0, "not implemented");
        //return this is src;
    }
    final override void fieldFormatter(StringSink sink, const(Value)* field) const
    {
        sink(values[field.sizet]);
    }
    final override string interpretString(IScope scope_, Value* outValue, string str)
    {
        assert(0, "not implemented");
    }
    override string interpretExpression(IScope scope_, Value* outValue, Expression expression)
    {
        // special case for symbols
        if(expression.type == ExpressionType.symbol)
        {
            foreach(i, value; values)
            {
                if(expression.source == value)
                {
                    outValue.sizet = i;
                    return null; // success
                }
            }
            auto error = defaultExpressionToValueEvaluator(expression, scope_, outValue, this);
            if(error)
            {
                return "it does not match any of the enum values and " ~ error;
            }
            return null; // success
        }
        else
        {
            return defaultExpressionToValueEvaluator(expression, scope_, outValue, this);
        }
    }
    override string tryProcessProperty(IScope scope_, Value* outValue, BidmakeStatementRangeReference statement)
    {
        statement.assertNoBlock.assertRemainingValueLength(1);
        return interpretExpression(scope_, outValue, statement.front);
    }
}
class ListType : Type
{
    Type elementType;
    this(Type elementType)
    {
        this.elementType = elementType;
    }
    // IBidmakeObject fields
    @property final string shallowTypeName() const { return "list"; }
    @property final string processTypeName() const { return elementType.shallowTypeName; }
    final inout(Interface) tryAsInterface() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final string interpretAsValue(IScope scope_, Value* outValue, Type type)
    {
        // TODO: assign the ListType itself to outValue
        assert(0, "not implemented");
    }
    final string interpretAsPrimitiveValue(IScope scope_, Value* outValue, PrimitiveType type)
    {
        assert(0, "not implemented");
    }
    final void onCall(IScope callScope, BidmakeStatement statement)
    {
        writefln("Error: you cannot call a list type");
        throw quit;
    }

    // Type fields
    final override inout(PrimitiveType) tryAsPrimitive() inout { return null; }
    final override inout(ListType) tryAsListType() inout { return this; }
    final override bool isAssignableFrom(const(Type) src) const
    {
        auto srcAsListType = src.tryAsListType();
        return srcAsListType && this.elementType.isAssignableFrom(srcAsListType.elementType);
    }
    final override bool secondCheckIsAssignableTo(const(Type) dst) const
    {
        assert(0, "not implemented");
    }
    final override void fieldFormatter(StringSink sink, const(Value)* field) const
    {
        sink("[");
        string prefix = "";
        foreach(ref element; field.list)
        {
            sink(prefix);
            prefix = ", ";
            elementType.fieldFormatter(sink, &element);
        }
        sink("]");
    }
    final override string interpretString(IScope scope_, Value* outValue, string str)
    {
        assert(0, "not implemented");
    }
    override string interpretExpression(IScope scope_, Value* outValue, Expression expression)
    {
        assert(0, "ListType.interpretExpression not implemented");
    }
    override string tryProcessProperty(IScope scope_, Value* outValue, BidmakeStatementRangeReference statement)
    {
        Value newElement;
        auto error = elementType.tryProcessProperty(scope_, &newElement, statement);
        if(error)
        {
            return error;
        }
        outValue.list ~= newElement;
        return null;
    }
}

interface IScope
{
    @property BidmakeFile getFile();
    @property DelegateFormatter formatScopeContext();
    IScope tryGetScope(const(char)[] name);
    IBidmakeObject tryGet(const(char)[] name);
    void addContract(Contract contract);    
}
IScope getScope(IScope scope_, const(char)[] name)
{
    auto result = scope_.tryGetScope(name);
    if(result is null)
    {
        writefln("Error: undefined identifier \"%s\" (scope=%s)", name, scope_);
        throw quit;
    }
    return result;
}

// This shouldn't be called directly to evaluate an expression, it's only used as a common
// implementation for other types to call.  To evaluate an expression, you should call
// <type>.interpretExpression. This function will just forward the call to other objects
// to evaluate it further.
string defaultExpressionToValueEvaluator(Expression expression, IScope scope_, Value *outValue, Type targetType)
{
    final switch(expression.type)
    {
        case ExpressionType.symbol:
            assert(expression.source is expression.string_); // sanity check
            auto resolved = lookupSymbol(scope_, expression.source);
            return resolved.interpretAsValue(scope_, outValue, targetType);
        case ExpressionType.string_:
            return targetType.interpretString(scope_, outValue, expression.string_);
        case ExpressionType.functionCall:
            return interpretCall(scope_, outValue, targetType, expression);
    }
}

Appender!(BidmakeFile[]) globalFilesLoaded;
BidmakeFile loadBidmakeFile(string pathFileCombo, Flag!"parse" parse)
{
    foreach(alreadyLoaded; globalFilesLoaded.data)
    {
        if(alreadyLoaded.dirAndFile.pathFileCombo == pathFileCombo)
        {
            writefln("[DEBUG] file \"%s\" has already been loaded", pathFileCombo);
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
    BidmakeStatement[] block;

    BidmakeFile redirect;
    private BidmakeFile[] imports;
    BidmakeFile[] includes;
    private Enum[] enums;
    private Define[] defines;
    private Interface[] interfaces;
    private Contractor[] contractors;
    Contract[] contracts;
    void addContract(Contract contract) { contracts ~= contract; }

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
            this.block = parseBidmake(dirAndFile.pathFileCombo, contents);
            this.state = BidmakeFileState.parsed;
        }
    }

    @property final auto pathFileCombo() const { return dirAndFile.pathFileCombo; }
    @property final auto dir() const { return dirAndFile.dir; }

    @property final auto formatLocation(string str)
        in { assert(str.ptr >= contents.ptr &&
                    str.ptr <= contents.ptr + contents.length); } body
    {
        static struct Formatter
        {
            BidmakeFile file;
            string str;
            void toString(StringSink sink) const
            {
                formattedWrite(sink, "%s(%s) ", file.pathFileCombo,
                    1 + count(file.contents[0 .. str.ptr - file.contents.ptr], '\n'));
            }
        }
        return Formatter(this, str);
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
    // for now both imports, enums and interfaces live in the same namespace
    //
    alias tryLookupImportContextSymbol   = tryLookupContext1Symbol;
    alias tryLookupEnumContextSymbol     = tryLookupContext1Symbol;
    alias tryLookupDefineContextSymbol   = tryLookupContext1Symbol;
    alias tryLookupInterfaceContextSymbol = tryLookupContext1Symbol;
    IBidmakeObject tryLookupContext1Symbol(const(char)[] name)
    {
        foreach(import_; imports)
        {
            if(import_.importName == name)
            {
                return import_;
            }
        }
        foreach(enum_; enums)
        {
            if(enum_.name == name)
            {
                return enum_;
            }
        }
        foreach(define; defines)
        {
            if(define.name == name)
            {
                return define;
            }
        }
        foreach(interface_; interfaces)
        {
            if(interface_.name == name)
            {
                return interface_;
            }
        }
        foreach(include; includes)
        {
            auto result = include.tryLookupContext1Symbol(name);
            if(result)
            {
                return result;
            }
        }
        return null;
    }

    //
    // IBidmakeObject Functions
    //
    @property final string shallowTypeName() const { return "file"; }
    @property final string processTypeName() const { return "file"; }
    inout(Interface) tryAsInterface() inout { return null; }
    inout(Type) tryAsType() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final string interpretAsValue(IScope scope_, Value* outValue, Type type)
    {
        assert(0, "not implemented");
    }
    final string interpretAsPrimitiveValue(IScope scope_, Value* outValue, PrimitiveType type)
    {
        assert(0, "not implemented");
    }
    void onCall(IScope callScope, BidmakeStatement statement)
    {
        writefln("Error: %s is a file, you cannot call it");
        throw quit;
    }

    //
    // IScope Functions
    //
    @property BidmakeFile getFile() { return this; }
    DelegateFormatter formatScopeContext()
    {
        return DelegateFormatter(&scopeContextFormatter);
    }
    private void scopeContextFormatter(StringSink sink)
    {
        formattedWrite(sink, "file \"%s\"", pathFileCombo);
    }
    IScope tryGetScope(const(char)[] name)
    {
        //writefln("[DEBUG] tryGetScope(file=%s, name=%s)", this, name);
        foreach(import_; imports)
        {
            //writefln("[DEBUG] tryGetScope checking import \"%s\"", import_.importName);
            if(import_.importName == name)
            {
                return import_;
            }
        }
        // not sure if I should also search the includes?
        return null;
    }
    IBidmakeObject tryGet(const(char)[] name)
    {
        //writefln("[DEBUG] tryGet(file=%s, name=%s)", this, name);
        // For now all return is enums and interfaces
        foreach(enum_; enums)
        {
            if(enum_.name == name)
            {
                return enum_;
            }
        }
        foreach(define; defines)
        {
            if(define.name == name)
            {
                return define;
            }
        }
        foreach(interface_; interfaces)
        {
            //writefln("[DEBUG] tryGetScope checking interface \"%s\"", interface_.name);
            if(interface_.name == name)
            {
                return interface_;
            }
        }
        foreach(include; includes)
        {
            auto result = include.tryGet(name);
            if(result)
            {
                return result;
            }
        }
        return null;
    }

    override string toString() const
    {
        return dirAndFile.pathFileCombo;
    }
}

class Define : IBidmakeObject
{
    Value value;
    Type type;
    string name;
    this(Value value, Type type, string name)
    {
        this.value = value;
        this.type = type;
        this.name = name;
    }

    // IBidmakeObject members
    @property final string shallowTypeName() const { return type.shallowTypeName; }
    @property final string processTypeName() const { return type.processTypeName; }
    inout(Interface) tryAsInterface() inout { return null; }
    inout(Type) tryAsType() inout { return null; }
    inout(Define) tryAsDefine() inout { return this; }
    final string interpretAsValue(IScope scope_, Value* outValue, Type type)
    {
        if(this.type.isAssignableFrom(type))
        {
            *outValue = this.value;
            return null;
        }
        return format("a value of type \"%s\" cannot be assigned to type \"%s\"", type.shallowTypeName, this.type.shallowTypeName);
    }
    final string interpretAsPrimitiveValue(IScope scope_, Value* outValue, PrimitiveType type)
    {
        if(this.type.isAssignableFrom(type))
        {
            *outValue = this.value;
            return null;
        }
        return format("a value of type \"%s\" cannot be assigned to type \"%s\"", type.shallowTypeName, this.type.shallowTypeName);
    }
    final void onCall(IScope callScope, BidmakeStatement statement)
    {
        assert(0, "cannot call a define variable");
    }
}

struct FieldID
{
    pragma(inline) @property static FieldID none() { return FieldID(size_t.max); }
    size_t index;
}
struct InterfaceField
{
    Type type;
    string name;
}
abstract class Interface : IBidmakeObject
{
    string name;
    this(string name)
    {
        this.name = name;
    }
    // IBidmakeObject members
    @property final string shallowTypeName() const { return "interface"; }
    @property final string processTypeName() const { return "interface"; }
    inout(Interface) tryAsInterface() inout { return this; }
    inout(Type) tryAsType() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final string interpretAsValue(IScope scope_, Value* outValue, Type type)
    {
        assert(0, "not implemented");
    }
    final string interpretAsPrimitiveValue(IScope scope_, Value* outValue, PrimitiveType type)
    {
        assert(0, "not implemented");
    }
    void onCall(IScope callScope, BidmakeStatement statement)
    {
        onCallImpl(this, callScope, statement);
    }

    //
    abstract InterfaceField getInlineField(size_t index);

    abstract @property size_t inlineFieldCount() const;
    abstract @property size_t fieldIDCount() const;
    abstract FieldID tryFindField(const(char)[] name);
    FieldID findField(T)(const(char)[] fieldName, lazy T errorContext)
    {
        FieldID id = tryFindField(fieldName);
        if(id == FieldID.none)
        {
            writefln("%sError: interface \"%s\" does not have a field named \"%s\"", errorContext, name, fieldName);
            throw quit;
        }
        return id;
    }

    abstract InterfaceField getField(FieldID id);
    abstract Type getFieldType(FieldID id);
    abstract void onCallImpl(Interface callInterface, IScope callScope, BidmakeStatement statement);

}
class ExplicitInterface : Interface
{
    size_t inlineCount;
    InterfaceField[] fields;
    this(string name, size_t inlineCount, InterfaceField[] fields)
    {
        super(name);
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
        return FieldID.none;
    }
    override InterfaceField getField(FieldID id)
    {
        return fields[id.index];
    }
    override Type getFieldType(FieldID id)
    {
        return fields[id.index].type;
    }
    override void onCallImpl(Interface callInterface, IScope callScope, BidmakeStatement callStatement)
    {
        auto statementInlines = callStatement.expressions[1..$];
        if(statementInlines.length > inlineCount)
        {
            // todo: this error message won't make alot of sense if this is a forward interface
            // todo: support optional inline values at the end
            writefln("Error: the \"%s\" interface can accept %s inline values but got %s",
                callInterface.name, inlineCount, statementInlines.length);
            throw quit;
        }

        auto contractFields = new Value[callInterface.fieldIDCount];
        {
            size_t inlineIndex = 0;
            for(; inlineIndex < statementInlines.length; inlineIndex++)
            {
                auto error = fields[inlineIndex].type.interpretExpression(callScope, &contractFields[inlineIndex], statementInlines[inlineIndex]);
                if(error)
                {
                    writefln("Error: failed to parse \"%s\" as type \"%s\" for field \"%s\" because %s",
                        statementInlines[inlineIndex], fields[inlineIndex].type.processTypeName, fields[inlineIndex].name, error);
                    throw quit;
                }
            }
            if(inlineIndex < inlineCount)
            {
                writefln("Error: optional inline values not implemented");
                throw quit;
            }
        }
        foreach(blockStatement; callStatement.block)
        {
            auto propName = blockStatement.frontExpressionAsSymbol();
            auto fieldID = tryFindField(propName);
            if(fieldID == FieldID.none)
            {
                writefln("Error: interface \"%s\" does not have a property named \"%s\"", callInterface.name,propName);
                throw quit;
            }
            auto fieldType = getFieldType(fieldID);

            auto error = fieldType.tryProcessProperty(callScope, &contractFields[fieldID.index], blockStatement.range(1));
            if(error)
            {
                writefln("Error: failed to process field \"%s\" as type \"%s\" because %s",
                   propName, fieldType.processTypeName, error);
                throw quit;
            }
        }
        callScope.addContract(new Contract(callInterface, contractFields));
    }
}
class ForwardInterface : Interface
{
    Interface forwardInterface;
    this(string name, Interface forwardInterface)
    {
        super(name);
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
        if(fieldID != FieldID.none)
        {
            return fieldID;
        }
        assert(0, "forward interface tryFindField not implemented");
    }
    override InterfaceField getField(FieldID id)
    {
        assert(0, "forward interface getField not implemented");
    }
    override Type getFieldType(FieldID id)
    {
        assert(0, "forward interface getFieldType not implemented");
    }
    override void onCallImpl(Interface callInterface, IScope callScope, BidmakeStatement statement)
    {
        // todo: for now just call the original interface as is
        writefln("WARNING: forwardInterface onCallImpl not implemented");
        forwardInterface.onCallImpl(callInterface, callScope, statement);
        assert(0, "not implemented");
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

class Contractor : IBidmakeObject
{
    string name;
    BuiltinContractor builtin;
    Interface[] interfaces;
    string[] actions;
    this(string name, BuiltinContractor builtin, Interface[] interfaces, string[] actions)
    {
        this.name = name;
        this.builtin = builtin;
        this.interfaces = interfaces;
        this.actions = actions;
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

    // IBidmakeObject methods
    @property final string shallowTypeName() const { return "contractor"; }
    @property final string processTypeName() const { return "contractor"; }
    // TODO: maybe this should return an interface?
    inout(Interface) tryAsInterface() inout { return null; }
    inout(Type) tryAsType() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final string interpretAsValue(IScope scope_, Value* outValue, Type type)
    {
        assert(0, "not implemented");
    }
    final string interpretAsPrimitiveValue(IScope scope_, Value* outValue, PrimitiveType type)
    {
        assert(0, "not implemented");
    }
    final void onCall(IScope callScope, BidmakeStatement statement)
    {
        assert(0, "calling contractor directly not implemented");
    }
}

union Value
{
    void* voidPtr;
    size_t sizet;
    string string_;
    Value[] list;
}

enum ValueDlangType
{
    voidPtr,
    sizet,
    string_,
    list
}

struct ContractTypedList(string ContractFieldMember)
{
    Value[] list;
    @property auto length() { return list.length; }
    auto elementAt(size_t index)
    {
        mixin("return list[index]." ~ ContractFieldMember ~ ";");
    }
    @property auto range()
    {
        struct Range
        {
            Value* next;
            Value* limit;
            @property size_t length() { return limit - next; }
            @property bool empty() { return next >= limit; }
            auto front() { mixin("return (*next)." ~ ContractFieldMember ~ ";"); }
            void popFront() { next++; }
        }
        return Range(list.ptr, list.ptr + list.length);
    }
}

class Contract : IBidmakeObject
{
    Interface interface_;
    Value[] fields;
    this(Interface interface_, Value[] fields)
    {
        this.interface_ = interface_;
        this.fields = fields;
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
        } else static assert(0, "lookupField primitive type not implemented");
    }
    private string lookupPrimitiveTypedStringField(string fieldName, PrimitiveTypeName expectedType)
    {
        auto fieldID = interface_.findField(fieldName, "");
        auto field = interface_.getField(fieldID);
        auto fieldPrimitiveType = field.type.tryAsPrimitive();
        if(fieldPrimitiveType is null || fieldPrimitiveType.name != expectedType)
        {
            writefln("Error: expected field \"%s\" on interface \"%s\" to be type '%s' but is '%s'",
                fieldName, interface_.name, expectedType, field.type.shallowTypeName);
            throw quit;
        }
        return fields[fieldID.index].string_;
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
        return ContractTypedList!(elementType.contractFieldMember)(fields[fieldID.index].list);
    }

    // IBidmakeObject methods
    @property final string shallowTypeName() const { return "contract"; }
    @property final string processTypeName() const { return "contract"; }
    inout(Interface) tryAsInterface() inout { return null; }
    inout(Type) tryAsType() inout { return null; }
    inout(Define) tryAsDefine() inout { return null; }
    final string interpretAsValue(IScope scope_, Value* outValue, Type type)
    {
        assert(0, "not implemented");
    }
    final string interpretAsPrimitiveValue(IScope scope_, Value* outValue, PrimitiveType type)
    {
        assert(0, "not implemented");
    }
    final void onCall(IScope callScope, BidmakeStatement statement)
    {
        writefln("Error: you cannot call a contract");
        throw quit;
    }

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
            interface_.getInlineField(i).type.fieldFormatter(sink, &fields[i]);
        }
        sink("\n{\n");
        foreach(i; interface_.inlineFieldCount..fields.length)
        {
            auto field = interface_.getField(FieldID(i));
            sink("   ");
            sink(field.name);
            sink(" ");
            field.type.fieldFormatter(sink, &fields[i]);
            sink("\n");
        }
        sink("}\n");
    }
}


string expressionAsSymbol(ref BidmakeStatement statement, size_t index)
{
    if(index >= statement.expressions.length)
    {
        // TODO: better error message
        writefln("Error: expected a symbol but got ", (statement.block is null) ? ";" : " a '{ block }'");
        throw quit;
    }
    if(statement.expressions[index].type != ExpressionType.symbol)
    {
        // TODO: better error message
        writefln("Error: expected a symbol but got \"%s\"", statement.expressions[index].type);
        throw quit;
    }
    // sanity check
    assert(statement.expressions[index].source is statement.expressions[index].string_);
    return statement.expressions[index].source; // Note
}
string frontExpressionAsSymbol(ref BidmakeStatement statement)
{
    return expressionAsSymbol(statement, 0);
}
auto ref assertMinExpressionCount(ref BidmakeStatement statement, size_t minExpressionCount)
{
    if(statement.expressions.length < minExpressionCount)
    {
        // TODO: better error message
        writefln("Error: the statement must have at least %s expression(s) but it has %s",
           minExpressionCount, statement.expressions.length);
        throw quit;
    }
    return statement;
}
auto ref assertExpressionCount(ref BidmakeStatement statement, size_t expectedExpressionCount)
{
    if(statement.expressions.length != expectedExpressionCount)
    {
        // TODO: better error message
        writefln("Error: the statement must have %s expression(s) but it has %s",
           expectedExpressionCount, statement.expressions.length);
        throw quit;
    }
    return statement;
}
auto ref assertRemainingValueLength(ref BidmakeStatementRangeReference statement, size_t expectedValueCount)
{
    if(statement.remainingValues != expectedValueCount)
    {
        // TODO: better error message
        writefln("Error: the statement must have %s remaining value(s) at offset %s but it has %s",
            expectedValueCount, statement.next, statement.remainingValues);
        throw quit;
    }
    return statement;
}
auto ref assertNoBlock(ref BidmakeStatement statement)
{
    if(statement.block !is null)
    {
        // TODO: better error message
        writefln("Error: unexpected statement block");
        throw quit;
    }
    return statement;
}
auto ref assertNoBlock(ref BidmakeStatementRangeReference statement)
{
    if(statement.statement.block !is null)
    {
        // TODO: better error message
        writefln("Error: unexpected statement block");
        throw quit;
    }
    return statement;
}
auto ref assertHasBlock(ref BidmakeStatement statement)
{
    if(statement.block is null)
    {
        // TODO: better error message
        writefln("Error: need statement block");
        throw quit;
    }
    return statement;
}

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


IBidmakeObject lookupSymbol(IScope scope_, string symbol)
{
    //writefln("[DEBUG] lookupSymbol \"%s\" in %s", symbol, scope_.formatScopeContext);
    auto peeled = PeeledName(null, symbol);
    for(;;)
    {
        peeled = peelQualifiedName(peeled.rest);
        if(peeled.rest is null)
        {
            break;
        }
        //writefln("[DEBUG]   - getScope \"%s\" in %s", peeled.nextName, scope_.formatScopeContext);
        scope_ = scope_.getScope(peeled.nextName);
    }

    //writefln("[DEBUG]   - get \"%s\" in %s", peeled.nextName, scope_.formatScopeContext);
    auto entry = scope_.tryGet(peeled.nextName);
    if(entry is null)
    {
        writefln("Error: %s does not contain a definition for symbol \"%s\"",
            scope_.formatScopeContext, symbol);
        throw quit;
    }
    return entry;
}

Type lookupType(IScope scope_, string typeSymbol)
{
    foreach(primitiveType; PrimitiveType.staticTypes)
    {
        if(typeSymbol == primitiveType.typeNameString)
        {
            return primitiveType.unconst;
        }
    }

    auto obj = lookupSymbol(scope_, typeSymbol);
    auto objAsType = obj.tryAsType();
    if(objAsType is null)
    {
        writefln("Error: expected a type but got \"%s\"", obj.shallowTypeName);
        throw quit;
    }
    return objAsType;
}


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
        auto operation = statement.frontExpressionAsSymbol();
        if(operation == "import")
        {
            statement.assertExpressionCount(2).assertNoBlock();
            importLibrary(bidmakeFile, statement.expressionAsSymbol(1));
        }
        else if(operation == "include")
        {
            statement.assertExpressionCount(2).assertNoBlock();
            addInclude(bidmakeFile, statement.expressionAsSymbol(1));
        }
        else if(operation == "redirect")
        {
            if(bidmakeFile.redirect)
            {
                writefln("Error: a file cannot contain multiple redirects");
                throw quit;
            }
            statement.assertExpressionCount(2).assertNoBlock();
            bidmakeFile.redirect = loadRedirect(bidmakeFile, statement.expressionAsSymbol(1));
        }
        else if(operation == "enum")
        {
            statement.assertExpressionCount(2).assertHasBlock();
            addEnumDefinition(bidmakeFile, statement.expressionAsSymbol(1), statement.block);
        }
        else if(operation == "define")
        {
            statement.assertExpressionCount(4).assertNoBlock();
            addDefine(bidmakeFile, statement.expressionAsSymbol(1), statement.expressionAsSymbol(2), statement.expressions[3]);
        }
        else if(operation == "interface")
        {
            statement.assertExpressionCount(2).assertHasBlock();
            addInterfaceDefinition(bidmakeFile, statement.expressionAsSymbol(1), statement.block);
        }
        else if(operation == "forwardInterface")
        {
            statement.assertExpressionCount(3).assertHasBlock();
            addForwardInterfaceDefinition(bidmakeFile, statement.expressionAsSymbol(1), statement.expressionAsSymbol(2), statement.block);
        }
        else if(operation == "contractor")
        {
            statement.assertExpressionCount(2).assertHasBlock();
            addContractor(bidmakeFile, statement.expressionAsSymbol(1), statement.block);
        }
        else
        {
            lookupSymbol(bidmakeFile, operation).onCall(bidmakeFile, statement);
        }
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
void importLibrary(BidmakeFile bidmakeFile, string importName)
{
    foreach(import_; bidmakeFile.imports)
    {
        if(import_.importName == importName)
        {
            writefln("library \"%s\" has already been imported");
            return;
        }
    }

    // find the library
    // 1. search in the same directory
    // 2. searcn in the global repository
    auto importNameWithExtension = importName ~ ".bidmake";
    string foundLibraryFilename = null;
    if(foundLibraryFilename is null)
    {
        auto libraryFilenameInSameDirectory = buildPath(bidmakeFile.dir, importNameWithExtension);
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
        writefln("[0] %s", bidmakeFile.dir.formatDir);
        writefln("[1] %s", globalRepoPath.formatDir);
        throw quit;
    }

    //writefln("[DEBUG] found import \"%s\" at \"%s\"", importName, foundLibraryFilename);
    auto importFile = loadBidmakeFile(foundLibraryFilename, Yes.parse);
    // note: analyzed may or may not be the same as importFile.  if the importFile
    //       has a redirect, it will not be the same
    auto analyzed = analyze(importFile);
    bidmakeFile.imports ~= analyzed;
}
void addInclude(BidmakeFile bidmakeFile, string includePath)
{
    auto includeFullPath = buildPath(bidmakeFile.dir, includePath);
    if(!exists(includeFullPath))
    {
        writefln("%sError: include \"%s\" does not exist at \"%s\"",
            bidmakeFile.formatLocation(includePath), includePath, includeFullPath);
    }
    if(isDir(includeFullPath))
    {
        foreach(entry; dirEntries(includeFullPath, "*.bidmake", SpanMode.shallow))
        {
            auto includeFile = loadBidmakeFile(entry.name, Yes.parse);
            auto analyzed = analyze(includeFile);
            bidmakeFile.includes ~= analyzed;
        }
    }
    else
    {
        auto includeFile = loadBidmakeFile(includeFullPath, Yes.parse);
        auto analyzed = analyze(includeFile);
        bidmakeFile.includes ~= analyzed;
    }
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
void addEnumDefinition(BidmakeFile bidmakeFile, string enumName, BidmakeStatement[] block)
{
    {
        auto existing = bidmakeFile.tryLookupInterfaceContextSymbol(enumName);
        if(existing !is null)
        {
            writefln("Error: enum name \"%s\" conflicts with existing %s", enumName, existing.shallowTypeName);
            throw quit;
        }
    }
    auto values = new string[block.length];
    foreach(i, statement; block)
    {
        statement.assertNoBlock();
        if(statement.expressions.length != 1)
        {
            writefln("Error: all Enum statements must be 1 expression, but this one has %s", statement.expressions.length);
            throw quit;
        }
        // todo: assert expression type
        values[i] = statement.expressionAsSymbol(0);
    }
    bidmakeFile.enums ~= new Enum(enumName, values);
}
void addDefine(BidmakeFile bidmakeFile, string typeName, string symbol, Expression valueExpression)
{
    auto type = lookupType(bidmakeFile, typeName);
    // check if symbol is already defined
    {
        auto existing = bidmakeFile.tryLookupDefineContextSymbol(symbol);
        if(existing !is null)
        {
            writefln("Error: define variable \"%s\" conflicts with existing %s", symbol, existing.shallowTypeName);
            throw quit;
        }
    }
    Value value;
    string error = type.interpretExpression(bidmakeFile, &value, valueExpression);
    if(error)
    {
        writefln("Error: invalid expression \"%s\" for type \"%s\": %s", valueExpression.source,
            typeName, error);
        throw quit;
    }
    bidmakeFile.defines ~= new Define(value, type, symbol);
    lookupSymbol(bidmakeFile, symbol);
}
void addInterfaceDefinition(BidmakeFile bidmakeFile, string interfaceName, BidmakeStatement[] block)
{
    auto existing = bidmakeFile.tryLookupInterfaceContextSymbol(interfaceName);
    if(existing !is null)
    {
        writefln("Error: interface name \"%s\" conflicts with existing %s", interfaceName, existing.shallowTypeName);
        throw quit;
    }
    auto fieldBuilder = appender!(InterfaceField[]);
    size_t statementIndex = 0;
    // parse inline statements first
    for(; statementIndex < block.length; statementIndex++)
    {
        auto statement = &block[statementIndex];
        if(statement.expressions.length == 0)
        {
            break;
        }
        if(statement.expressions[0].source == "inline")
        {
            fieldBuilder.put(processInterfaceTypeField(bidmakeFile, statement.range(1)));
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
            writefln("[DEBUG] ignoring action for now");
        }
        else if(operation == "inline")
        {
            writefln("Error: inline statements must appear at the beginning of the interface");
            throw quit;
        }
        else if(operation == "list")
        {
            auto field = processInterfaceTypeField(bidmakeFile, statement.range(1));
            field.type = new ListType(field.type);
            fieldBuilder.put(field);
        }
        else
        {
            Type type = null;
            if(type is null)
            {
                foreach(primitiveType; PrimitiveType.staticTypes)
                {
                    if(operation == primitiveType.typeNameString)
                    {
                        type = primitiveType.unconst;
                        break;
                    }
                }
            }
            if(type is null)
            {
                auto obj = lookupSymbol(bidmakeFile, operation);
                type = obj.tryAsType();
                if(type is null)
                {
                    writefln("Error: expected a type but got \"%s\"", obj.shallowTypeName);
                    throw quit;
                }
            }
            (*statement).assertExpressionCount(2).assertNoBlock();
            fieldBuilder.put(InterfaceField(type, (*statement).expressionAsSymbol(1)));
        }
    }
    bidmakeFile.interfaces ~= new ExplicitInterface(interfaceName, inlinePropertyCount, fieldBuilder.data);
}

InterfaceField processInterfaceTypeField(BidmakeFile bidmakeFile, BidmakeStatementRangeReference statement)
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

    auto type = lookupType(bidmakeFile, typeString);
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

    return InterfaceField(type, fieldName);
}

void addForwardInterfaceDefinition(BidmakeFile bidmakeFile, string interfaceName, string forwardInterfaceName, BidmakeStatement[] block)
{
    auto existing = bidmakeFile.tryLookupInterfaceContextSymbol(interfaceName);
    if(existing !is null)
    {
        writefln("Error: interface name \"%s\" conflicts with existing %s", interfaceName, existing.shallowTypeName);
        throw quit;
    }
    auto forwardInterfaceObject = bidmakeFile.tryLookupInterfaceContextSymbol(forwardInterfaceName);
    if(forwardInterfaceObject is null)
    {
        writefln("Error: the interface to forward to \"%s\" does not exist", forwardInterfaceName);
        throw quit;
    }
    auto forwardInterface = forwardInterfaceObject.tryAsInterface();
    if(forwardInterface is null)
    {
        writefln("Error: cannot create a forwardInterface to \"%s\" because it's type is \"%s\"", forwardInterfaceName, forwardInterfaceObject.shallowTypeName);
        throw quit;
    }
    // todo: process the forward interface
    bidmakeFile.interfaces ~= new ForwardInterface(interfaceName, forwardInterface);
}

void addContractor(BidmakeFile bidmakeFile, string contractorName, BidmakeStatement[] block)
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
            (*statement).assertExpressionCount(2).assertNoBlock();
            auto obj = lookupSymbol(bidmakeFile, (*statement).expressionAsSymbol(1));
            auto objAsInterface = obj.tryAsInterface();
            if(!objAsInterface)
            {
                writefln("%sError: expected an interface but the type is \"%s\"",
                    bidmakeFile.formatLocation((*statement).expressionAsSymbol(1)), obj.shallowTypeName);
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
            (*statement).assertExpressionCount(2).assertNoBlock();
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
            else
            {
                writefln("Error: contractor \"%s\" is 'builtin' but no implmentation exists");
                throw quit;
            }
        }
        else
        {
            writefln("%sError: unknown contractor statement \"%s\"", bidmakeFile.formatLocation(operation), operation);
            throw quit;
        }
    }
    bidmakeFile.contractors ~= new Contractor(contractorName, builtin, interfaces, actions);
}
