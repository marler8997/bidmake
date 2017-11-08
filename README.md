# bidmake

An idea and proof-of-concept implementation for a build system.

The idea is to take the work of creating/maintaining a build system away from indivudual projects and spread it to the build tools themselves. The analogy I've chosen to distinguish between these roles is "BuildContract" and "BuildContractor".

> Note: Maybe an easier analogy would be "blueprint" and "builder"?
> Another analagy might be "Plan" and "Builder"?

A "BuildContract" is a blueprint that describes something to be built.  A "BuildContractor" is a tool that can build/fullfill a BuildContract.  This seperation of responsibility allows projects to define themselves using generic interfaces without having to tie themselves to particular build tools.  This severs any dependency the project has on specific build tools allowing developers to interchange any build tool that can understand a project's BuildContract.

There are also cases where a tool is self-contained within a project.  The tool is only used in the project and performs a simple function on the project.  An example of this is a code generation tool.  This type of tool does fit the BuildContract/BuildContractor analogy.  Therefore there is a construct that combines both BuildContract and BuildContractor called a "BuildStep".

## Example

helloWorld.bidmake
```
import dlang;
dlang.exe "helloWorld"
{
    source "helloWorld.d"
}
```

## How to use

> TODO: this tool will be compiled (it won't require having the Dlang compiler to use).  I should include
>       the instructions for how to build the tool here.  It should be able to build itself but it might
>       also make sense to have a bootstrap build option (batch file for Windows/Makefile for posix).


## The Developer Install

The "Developer Install" is a way to install bidmake so that it runs directly from source.  This is useful if you want to maintain a fast modify/test cycle.  This technique makes use of the `rdmd` tool that comes with the dmd compiler.  The idea is that instead of installing the "bb" exectuable, you install a script that uses rdmd to call "bb" directly from source.

### Windows

Create a batch script named "bb.bat" somewhere in your PATH with the following content:
```
@rdmd -g -debug <location-of-this-repo>\bb.d %*
```

### Posix (Linux, Max, etc.)

Create a shell script named "bb" somewhere in your PATH with the following content:
```
rdmd -g -debug <location-of-this-repo>/bb.d $@
```
> Note: remember to make it executable `chmod +x b`
