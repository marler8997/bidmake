// How to run
// rdmd bmschemagen.d standard.bmschema
module bmschemagen;

import std.stdio : File;
import std.string : lastIndexOf;
import std.path : dirName, baseName, buildPath, setExtension, stripExtension;

import util;
import bidmake.parser;

__gshared File output;
__gshared string moduleName;

int main(string[] args)
{
    args = args[1..$];
    if(args.length != 2)
    {
        import std.stdio : writeln;
        writeln("Usage: bbschemagen <module-name> <schema-file>");
        return 1;
    }
    moduleName = args[0];
    auto schemaFile = args[1];
    auto text = readFile(schemaFile).castImmutable;
    try
    {
        auto schemaNodes = parseBidmake(schemaFile, text);
        if(schemaNodes is null)
        {
            // error should already be logged
            return 1;
        }

        processInterfaces(schemaNodes);

        auto schemaFileBaseName = schemaFile.baseName();
        auto outputFilename = buildPath(schemaFile.dirName(), moduleFilename(moduleName));
        output = File(outputFilename, "wb");
        return generateCode(schemaFile, schemaNodes);
    }
    catch(QuitException)
    {
        return 1;
    }
}


auto moduleFilename(const(char)[] moduleName)
{
    auto lastDotIndex = moduleName.lastIndexOf('.');
    if(lastDotIndex >= 0)
    {
        moduleName = moduleName[lastDotIndex + 1 .. $];
    }
    return moduleName ~ ".d";
}

struct Interface
{
    string name;
    TypeAndName[] props;
}

Interface[string] interfaceMap;

void processInterfaces(BidMakeProperty[] props)
{
    foreach(prop; props)
    {
        if(prop.name == "Enum")
        {
        }
        else if(prop.name == "Interface")
        {
            auto nameAndBlock = NameAndBlock("Interface", prop);
            auto existing = interfaceMap.get(nameAndBlock.name, Interface());
            if(existing.name !is null)
            {
                output.writefln("Error: multiple interfaces named \"%s\"", nameAndBlock.name);
                throw quit;
            }
            auto interfaceProps = new TypeAndName[nameAndBlock.properties.length];
            size_t i = 0;
            foreach(interfaceProp; nameAndBlock.properties)
            {
                interfaceProps[i] = asTypedNameProperty("interface property", interfaceProp);
                i++;
            }
            interfaceMap[nameAndBlock.name] = Interface(nameAndBlock.name, interfaceProps);
        }
        else if(prop.name == "Define")
        {
            // Todo add an entry in the symbol table for this define
        }
        else
        {
            output.writefln("Error: unhandled schema property \"%s\"", prop.name);
            throw quit;
        }
    }
}

int generateCode(string filename, BidMakeProperty[] props)
{
    output.writefln("// This file was generated from \"%s\"", filename);
    output.writefln("module %s;", moduleName);
    output.writeln();
    output.writeln("import std.stdio;");
    output.writeln(`
// User Defined Attribute. Indicates the member is not a property.
struct NotAProperty { }
// User Defined Attribute. Indicates the field should be before the block section.
struct RequiredInlineProperty {}
struct OptionalInlineProperty {}
`);

    foreach(prop; props)
    {
        if(prop.name == "Enum")
        {
            generateEnum(prop);
        }
        else if(prop.name == "Interface")
        {
            generateInterface(prop);
        }
        else if(prop.name == "Define")
        {
            generateDefine(prop);
        }
        else
        {
            output.writefln("Error: unhandled schema property \"%s\"", prop.name);
            throw quit;
        }
    }
    return 0;
}


auto formatBlockCount(BidMakeProperty[] properties)
{
    struct Formatter
    {
        size_t count;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            if(count == 0)
            {
                sink("no block");
            }
        }
    
    }
}
struct NameAndBlock
{
    string name;
    BidMakeProperty[] properties;
    this(string context, BidMakeProperty property)
    {
        if(property.values.length != 1)
        {
            output.writefln("Error: expected %s to be followed by a 1 value but has %s", context, property.values.length);
            throw quit;
        }
        if(property.properties is null)
        {
            output.writefln("Error: %s must have a property block", context);
            throw quit;
        }
        this.name = property.values[0];
        this.properties = property.properties;
    }
}

void generateEnum(BidMakeProperty property)
{
    auto def = NameAndBlock("Enum", property);
    output.writefln("enum %s", def.name);
    output.writeln("{");
    output.writeln("    // values not implemented");
    output.writeln("}");
}
void generateInterface(BidMakeProperty property)
{
    auto def = NameAndBlock("Interface", property);
    auto iface = interfaceMap.get(def.name, Interface());
    assert(iface.name !is null);

    output.writefln("struct %sInterface", def.name);
    output.writeln("{");
    foreach(prop; iface.props)
    {
        output.writefln("    %s function(void*) %s;", prop.type, prop.name);
    }
    output.writeln("}");
}
void generateDefine(BidMakeProperty property)
{
    auto def = NameAndBlock("Define", property);
    output.writefln("struct %s", def.name);
    output.writeln("{");
    generateProperties(def.properties);
    output.writeln("}");
}

enum TypeID
{
    string,
    identifier,
    bool_,
    userDefined,
}

struct Type
{
    TypeID id;
    string stringValue;
    this(string stringValue)
    {
        if(stringValue == "String")
        {
            this.id = TypeID.string;
        }
        else if(stringValue == "Identifier")
        {
            this.id = TypeID.identifier;
        }
        else if(stringValue == "Bool")
        {
            this.id = TypeID.bool_;
        }
        else
        {
            // TODO: look up the user defined type in the symbol table
            this.id = TypeID.userDefined;
        }
        this.stringValue = stringValue;
    }
    string toString()
    {
        final switch(id)
        {
            case TypeID.string: return "string";
            case TypeID.identifier: return "string";
            case TypeID.bool_: return "bool";
            case TypeID.userDefined: return moduleName ~ "." ~ stringValue;
        }
    }
}

auto processOneValue(BidMakeProperty property)
{
    if(property.values.length != 1)
    {
        output.writefln("Error: property %s must have 1 value but has %s", property.name, property.values.length);
        throw quit;
    }
    return property.values[0];
}

struct TypeAndName
{
    Type type;
    string name;
}

auto asTypedNameProperty(string context, BidMakeProperty property)
{
    auto type = Type(property.name);
    if(property.values.length != 1)
    {
        output.writefln("Error: expected a type followed by 1 name value, but got %s values", property.values.length);
        throw quit;
    }
    if(property.properties !is null)
    {
        output.writefln("Error: this property cannot have it's own block");
        throw quit;
    }
    return TypeAndName(type, property.values[0]);
}

/+
auto processTypeAndName(string context, string[] values)
{
}
+/
auto asTypeAndNameProperty(BidMakeProperty property)
{
    if(property.values.length != 2)
    {
        output.writefln("Error: the \"%s\" property requires 2 values (a type and name) but got %s",
            property.name, property.values.length);
        throw quit;
    }
    if(property.properties !is null)
    {
        output.writefln("Error: the \"%s\" property cannot have it's own block", property.name);
        throw quit;
    }
    return TypeAndName(Type(property.values[0]), property.values[1]);
}

void generateProperties(BidMakeProperty[] props)
{
    foreach(prop; props)
    {
        if(prop.name == "Property")
        {
            auto result = asTypeAndNameProperty(prop);
            output.writefln("    %s %s;", result.type, result.name);
        }
        else if(prop.name == "List")
        {
            auto result = asTypeAndNameProperty(prop);
            output.writefln("    %s[] %sList;", result.type, result.name);
        }
        else if(prop.name == "OptionalInlineProperty")
        {
            auto result = asTypeAndNameProperty(prop);
            output.writeln("    @OptionalInlineProperty");
            output.writefln("    %s %s;", result.type, result.name);
        }
        else if(prop.name == "RequiredInlineProperty")
        {
            auto result = asTypeAndNameProperty(prop);
            output.writeln("    @RequiredInlineProperty");
            output.writefln("    %s %s;", result.type, result.name);
        }
        else if(prop.name == "Implement")
        {
            auto interfaceName = processOneValue(prop);
            auto iface = interfaceMap.get(interfaceName, Interface());
            if(iface.name is null)
            {
                output.writefln("Error: undefined interface \"%s\"", interfaceName);
                throw quit;
            }
            generateInterfaceImplementation(iface);
        }
        else
        {
            output.writefln("Error: unhandled schema property \"%s\"", prop.name);
            throw quit;
        }
    }
}

void generateInterfaceImplementation(Interface iface)
{
    foreach(prop; iface.props)
    {
        output.writefln("    private static %s %sInterfaceImpl%s(void* this_)", prop.type, iface.name, prop.name);
        output.writeln ("    {");
        output.writefln("        return (cast(typeof(this)*)this_).%s;", prop.name);
        output.writeln ("    }");
    }
    output.writeln ("    @NotAProperty");
    output.writefln("    @property auto as%s()", iface.name);
    output.writeln ("    {");
    output.writef("        return %sInterface(", iface.name);
    foreach(i, prop; iface.props)
    {
        if(i == 0)
            output.writeln();
        else
            output.writeln(",");
        output.writef("            &%sInterfaceImpl%s", iface.name, prop.name);
    }
    output.writeln(");");
    output.writeln ("    }");
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