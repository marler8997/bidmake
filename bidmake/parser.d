module bidmake.parser;

import std.array : Appender;
import std.format : format;
import std.conv : to;
import std.algorithm : startsWith;
import util : immutable_cstring, Builder, GCDoubler, StringSink, formatQuotedIfSpaces, writeEscaped;
import utf8;

enum ExpressionType
{
    symbol,
    string_,
    functionCall,
}

struct FunctionCall
{
    size_t sourceNameLength;
    Expression[] args;
}

struct Expression
{
    string source;
    ExpressionType type;
    union
    {
        // Note: the "string_" field may or may not be a slice of "source"
        // If it is a symbol, then it MUST be equal to source.
        // If it is a string_, then source will be the full quoted source string, and string_
        // will be the source without the quotes if there are no escapes, otherwise, it will
        // be a new string outside the source with the escapes handled.
        string string_;
        FunctionCall functionCall;
    }
    private this(string source, ExpressionType type, string string_)
    {
        this.source = source;
        this.type = type;
        this.string_ = string_;
    }
    private this(string source, FunctionCall functionCall)
    {
        this.source = source;
        this.type = ExpressionType.functionCall;
        this.functionCall = functionCall;
    }

    static Expression createSymbol(string source)
    {
        return Expression(source, ExpressionType.symbol, source);
    }
    static Expression createString(string source, string processedString)
    {
        return Expression(source, ExpressionType.string_, processedString);
    }
    static Expression createFunctionCall(string source, string name, Expression[] args)
    {
        assert(source.ptr == name.ptr);
        return Expression(source, FunctionCall(name.length, args));
    }

    @property string functionName() const
    {
        return source[0 .. functionCall.sourceNameLength];
    }
    void toString(StringSink sink) const
    {
        sink(source);
    }
}

struct BidmakeStatement
{
    Expression[] expressions;
    BidmakeStatement[] block;
    auto range(size_t nameValueOffset)
    {
        return BidmakeStatementRangeReference(&this, nameValueOffset);
    }
    void toString(StringSink sink) const
    {
        string prefix = "";
        foreach(expression; expressions)
        {
            sink(prefix);
            sink(expression.source);
            prefix = " ";
        }
        if(block is null)
        {
            sink(";");
        }
        else
        {
            sink("{");
            foreach(property; block)
            {
                property.toString(sink);
            }
            sink("}");
        }
    }
}

private struct BidmakeStatementRangeReference
{
    BidmakeStatement* statement;
    size_t next;
    @property bool empty() { return next >= statement.expressions.length; }
    auto front()
    {
        return statement.expressions[next];
    }
    void popFront() { next++; }
    @property final size_t remainingValues()
    {
        return statement.expressions.length - next;
    }
}

struct DefaultNodeBuilder
{
    static struct BlockBuilder
    {
        Builder!(BidmakeStatement, GCDoubler!32) builder;
        this(size_t depth)
        {
        }
        void newStatement(Expression[] expressions, BidmakeStatement[] block)
        {
            builder.makeRoomFor(1);
            builder.buffer[builder.dataLength++] = BidmakeStatement(expressions, block);
        }
        auto finish()
        {
            builder.buffer.length = builder.dataLength;
            return builder.buffer;
        }
    }
    static struct ExpressionBuilder
    {
        Expression[10] firstValues;
        Builder!(Expression, GCDoubler!20) extraValues;
        ubyte state;
        void append(Expression expression)
        {
            if(state < firstValues.length)
            {
                firstValues[state++] = expression;
            }
            else
            {
                if(state == firstValues.length)
                {
                    extraValues.append(firstValues);
                    state++;
                }
                extraValues.append(expression);
            }
        }
        auto finish()
        {
            if(state == 0)
            {
                return null;
            }
            else if(state <= firstValues.length)
            {
                return firstValues[0..state].dup;
            }
            else
            {
                return extraValues.data;
            }
        }
    }
}

struct DefaultBidmakeParserHooks
{
    alias NodeBuilder = DefaultNodeBuilder;
}

auto parseBidmake(string filename, string text)
{
    //BidmakeGCAllocator allocator;
    auto parser = BidmakeParser!DefaultBidmakeParserHooks(filename, text.ptr, 1);
    return parser.parse();
}

class ParseException : Exception
{
    this(string msg, string filename, uint lineNumber)
    {
        super(msg, filename, lineNumber);
    }
}

static struct PeekedChar
{
    dchar nextChar;
    const(char)* nextNextPtr;
}
private bool validNameFirstChar(dchar c)
{
    return
        (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c == '_') ||
        (c == '.') ||
        (c == '/');
}
private bool validNameChar(dchar c)
{
    return
        validNameFirstChar(c) ||
        (c >= '0' && c <= '9');
}


struct BidmakeParser(Hooks)
{
    string filenameForErrors;
    uint lineNumber;
    immutable_cstring nextPtr;
    dchar current;
    immutable_cstring currentPtr;
    this(string filenameForErrors, immutable_cstring nextPtr, uint lineNumber = 1)
    {
        this.filenameForErrors = filenameForErrors;
        this.nextPtr = nextPtr;
        this.lineNumber = lineNumber;
    }

    auto parseException(T...)(string fmt, T args)
    {
        return new ParseException(format(fmt, args), filenameForErrors, lineNumber);
    }

    BidmakeStatement[] parse()
    {
        // read the first character
        consumeChar();
        return parseBlock(0);
    }
    private BidmakeStatement[] parseBlock(size_t depth)
    {
        //import std.stdio;
        //writefln("parseBlock(depth=%s, line=%s)", depth, lineNumber);
        auto blockBuilder = Hooks.NodeBuilder.BlockBuilder(depth);

        for(;;)
        {
            // parse expressions
            Expression[] expressions;
            {
                auto expressionBuilder = Hooks.NodeBuilder.ExpressionBuilder();
                for(;;)
                {
                    auto expression = tryPeelExpression();
                    if(expression.source is null)
                    {
                        break;
                    }
                    expressionBuilder.append(expression);
                }
                expressions = expressionBuilder.finish();
            }

            if(expressions.length == 0)
            {
                if(current == '\0')
                {
                    if(depth == 0)
                    {
                        break;
                    }
                    throw parseException("not enough closing curly-braces");
                }
                if(current == '}')
                {
                    if(depth == 0)
                    {
                        throw parseException("too many closing curly-braces");
                    }
                    consumeChar();
                    break;
                }
                if(current == '{')
                {
                    consumeChar();
                    blockBuilder.newStatement(null, parseBlock(depth + 1));
                }
                else
                {
                    throw parseException("expected an expression, or a '{ block }' but got %s", escapedToken(currentPtr));
                }
            }
            else
            {
                if(current == ';')
                {
                    consumeChar();
                    blockBuilder.newStatement(expressions, null);
                }
                else if(current == '{')
                {
                    consumeChar();
                    blockBuilder.newStatement(expressions, parseBlock(depth + 1));
                }
                else
                {
                    throw parseException("expected statement to end with ';' or '{ block }' but got %s", escapedToken(currentPtr));
                }
            }
        }
        return blockBuilder.finish();
    }
    pragma(inline) void consumeChar()
    {
        currentPtr = nextPtr;
        current = decodeUtf8(&nextPtr);
    }
    // NOTE: only call if you know you are not currently pointing to the
    //       terminating NULL character
    const PeekedChar peek() in { assert(current != '\0'); } body
    {
        PeekedChar peeked;
        peeked.nextNextPtr = nextPtr;
        peeked.nextChar = decodeUtf8(&peeked.nextNextPtr);
        return peeked;
    }

    void skipToNextLine()
    {
        for(;;)
        {
            auto c = decodeUtf8(&nextPtr);
            if(c == '\n')
            {
                lineNumber++;
                return;
            }
            if(c == '\0')
            {
                currentPtr = nextPtr;
                current = '\0';
                return;
            }
        }
    }
    void skipWhitespaceAndComments()
    {
        for(;;)
        {
            if(current == ' ' || current == '\t' || current == '\r')
            {
                //do nothing
            }
            else if(current == '\n')
            {
                lineNumber++;
            }
            else if(current == '/')
            {
                auto next = peek(); // Note: we know current != '\0'
                if(next.nextChar == '/')
                {
                    skipToNextLine();
                    if(current == '\0')
                    {
                        return;
                    }
                }
                else if(next.nextChar == '*')
                {
                    assert(0, "multiline comments not implemented");
                }
                else
                {
                    return; // not a whitespace or comment
                }
            }
            else
            {
                return; // not a whitespace or comment
            }
            consumeChar();
        }
    }
    auto tryPeelName()
    {
        skipWhitespaceAndComments();
        if(!validNameFirstChar(current))
        {
            return null;
        }
        auto nameStart = currentPtr;
        for(;;)
        {
            consumeChar();
            if(!validNameChar(current))
            {
                return nameStart[0..currentPtr-nameStart];
            }
        }
    }


    Expression tryPeelExpression()
    {
        for(;;)
        {
            Expression part = tryPeelExpressionLevel0();
            if(part.source is null)
            {
                return part;
            }
            skipWhitespaceAndComments();
            // TODO: check for operations such as '+' etc
            return part;
        }
    }
    // Level 0 expressions are the expressions with the highest operator precedence.
    // 1) symbol
    // 2) function call (symbol '(' args.. ')')
    // 3) string
    Expression tryPeelExpressionLevel0()
    {
        skipWhitespaceAndComments();
        if(validNameFirstChar(current))
        {
            auto nameStart = currentPtr;
            for(;;)
            {
                consumeChar();
                if(!validNameChar(current))
                {
                    auto name = nameStart[0..currentPtr-nameStart];
                    skipWhitespaceAndComments();
                    if(current == '(')
                    {
                        return peelFunctionCall(name);
                    }
                    return Expression.createSymbol(name);
                }
            }
        }
        if(current == '"')
        {
            return peelString();
        }
        return Expression(); // no level0 expression was found
    }
    // Assumption: current is at the opening quote
    Expression peelString()
    {
        auto start = currentPtr;
        immutable_cstring firstEscape = null;
        for(;;)
        {
            consumeChar();
            if(current == '"')
            {
                break;
            }
            if(current == '\\')
            {
                if(!firstEscape)
                {
                    firstEscape = currentPtr;
                }
                assert(0, "escapes not implemented");
            }
            else if(current == '\n')
            {
                // TODO: maybe provide a way to allow this
                throw parseException("double-quoted strings cannot contain newlines");
            }
            else if(current == '\0')
            {
                throw parseException("file ended inside double-quoted string");
            }
        }
        if(!firstEscape)
        {
            consumeChar();
            auto source = start[0 .. currentPtr - start];
            auto str = source[1..$-1];
            return Expression.createString(source, str);
        }
        assert(0, "escapes not implemented");
    }
    // Assumption: current points to opening paren
    Expression peelFunctionCall(string name)
    {
        auto sourceStart = name.ptr;
        auto expressionBuilder = Hooks.NodeBuilder.ExpressionBuilder();

        consumeChar();
        skipWhitespaceAndComments();
        if(current != ')')
        {
            for(;;)
            {
                auto expression = tryPeelExpression();
                if(expression.source is null)
                {
                    throw parseException("expected function call to end with ')' but got '%s'", escapedToken(currentPtr));
                }
                expressionBuilder.append(expression);
                skipWhitespaceAndComments();
                if(current == ')')
                {
                    break;
                }
                if(current != ',')
                {
                    throw parseException("expected comma ',' after function argument but got '%s'", escapedToken(currentPtr));
                }
                consumeChar();
            }
        }
        consumeChar();
        auto source = sourceStart[0 .. currentPtr - sourceStart];
        return Expression.createFunctionCall(source, name, expressionBuilder.finish());
    }
}
auto guessEndOfToken(const(char)* ptr)
{
    // TODO: should use the first token to determine the kind of token and
    //       then find the end using that information
    for(;;)
    {
        auto c = *ptr;
        if(c == '\0' || c == ' ' || c == '\t' || c == '\r' || c == '\n')
        {
            return ptr;
        }
        decodeUtf8(&ptr);
    }
}
auto escapedToken(const(char)* token)
{
    struct Formatter
    {
        const(char)* token;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            if(*token == '\0')
            {
                sink("EOF");
            }
            else
            {
                sink("\"");
                sink.writeEscaped(token, guessEndOfToken(token));
                sink("\"");
            }
        }
    }
    return Formatter(token);
}