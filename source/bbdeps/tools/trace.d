/**
 * Copyright: Copyright Jason White, 2016
 * License:   MIT
 * Authors:   Jason White
 *
 * Description:
 * The fallback for what to do when no other tool can handle dependency
 * detection. This is much slower than handling dependency detection in an
 * ad-hoc manner and should be used as a last resort.
 *
 * TODO: Use ptrace directly instead of parsing the output of strace.
 */
module deps.tools.trace;

import io.file;
import deps.logger;

version (Posix)
{

private struct Trace
{
    /**
     * Paths that start with these fragments are ignored.
     */
    private static immutable ignoredPaths = [
        "/dev/",
        "/etc/",
        "/proc/",
        "/tmp/",
        "/usr/",
    ];

    /**
     * Returns: True if the given path should be ignored, false otherwise.
     */
    private static bool ignorePath(const(char)[] path) pure nothrow
    {
        import std.algorithm.searching : startsWith;

        foreach (ignored; ignoredPaths)
        {
            if (path.startsWith(ignored))
                return true;
        }

        return false;
    }

    private
    {
        import std.container.rbtree;

        DepsLogger logger;

        // Current working directories of each tracked process.
        string[int] processes;

        RedBlackTree!string inputs, outputs;
    }

    this(DepsLogger logger)
    {
        this.logger = logger;

        inputs = redBlackTree!string();
        outputs = redBlackTree!string();
    }

    ~this()
    {
        foreach (f; inputs)
            logger.addInput(f);

        foreach (f; outputs)
            logger.addOutput(f);
    }

    string filePath(int pid, const(char)[] path)
    {
        import std.path : buildNormalizedPath;

        if (auto p = pid in processes)
            return buildNormalizedPath(*p, path);

        return buildNormalizedPath(path);
    }

    void parse(File f)
    {
        import io.text;
        import std.conv : parse, ConvException;
        import std.string : munch;
        import std.algorithm.searching : startsWith;
        import std.regex : regex, matchFirst;

        auto re_open   = regex(`open\("([^"]*)", ([^,)]*)`);
        auto re_creat  = regex(`creat\("([^"]*)",`);
        auto re_rename = regex(`rename\("([^"]*)", "([^"]*)"\)`);
        auto re_mkdir  = regex(`mkdir\("([^"]*)", (0[0-7]*)\)`);
        auto re_chdir  = regex(`chdir\("([^"]*)"\)`);

        foreach (line; f.byLine)
        {
            int pid;

            try
                pid = line.parse!int();
            catch (ConvException e)
                continue;

            line.munch(" \t");

            if (line.startsWith("open"))
            {
                auto captures = line.matchFirst(re_open);
                if (captures.empty)
                    continue;

                open(pid, captures[1], captures[2]);
            }
            else if (line.startsWith("creat"))
            {
                auto captures = line.matchFirst(re_open);
                if (captures.empty)
                    continue;

                creat(pid, captures[1]);
            }
            else if (line.startsWith("rename"))
            {
                auto captures = line.matchFirst(re_rename);
                if (captures.empty)
                    continue;

                rename(pid, captures[1], captures[2]);
            }
            else if (line.startsWith("mkdir"))
            {
                auto captures = line.matchFirst(re_mkdir);
                if (captures.empty)
                    continue;

                mkdir(pid, captures[1]);
            }
            else if (line.startsWith("chdir"))
            {
                auto captures = line.matchFirst(re_chdir);
                if (captures.empty)
                    continue;

                chdir(pid, captures[1]);
            }
        }
    }

    void open(int pid, const(char)[] path, const(char)[] flags)
    {
        import std.algorithm.iteration : splitter;

        if (ignorePath(path))
            return;

        foreach (flag; splitter(flags, '|'))
        {
            if (flag == "O_WRONLY" || flag == "O_RDWR")
            {
                // Opened in write mode. It's an output even if it was read
                // before.
                auto f = filePath(pid, path);
                inputs.removeKey(f);
                outputs.insert(f);
                break;
            }
            else if (flag == "O_RDONLY")
            {
                // Opened in read-only mode. It's an input unless it's already
                // an output. Consider the scenario of writing a new file and
                // then reading it back in. In such cases, the file should only
                // be considered an output.
                auto f = filePath(pid, path);
                if (f !in outputs)
                    inputs.insert(f);
                break;
            }
        }
    }

    void creat(int pid, const(char)[] path)
    {
        if (ignorePath(path))
            return;

        outputs.insert(filePath(pid, path));
    }

    void rename(int pid, const(char)[] from, const(char)[] to)
    {
        if (ignorePath(to))
            return;

        auto output = filePath(pid, to);
        outputs.removeKey(filePath(pid, from));
        inputs.removeKey(output);
        outputs.insert(output);
    }

    void mkdir(int pid, const(char)[] dir)
    {
        outputs.insert(filePath(pid, dir));
    }

    void chdir(int pid, const(char)[] path)
    {
        processes[pid] = path.idup;
    }
}

int trace(DepsLogger logger, string[] args)
{
    import std.string : toStringz;
    import std.file : remove;
    import std.process : wait, spawnProcess, ProcessException;

    auto traceLog = tempFile(AutoDelete.no).path;
    scope (exit) remove(traceLog);

    auto traceArgs = [
        "strace",

        // Follow child processes
        "-f",

        // Output to a file to avoid mixing the child's output
        "-o", traceLog,

        // Only trace the sys calls we are interested in
        "-e", "trace=open,creat,rename,mkdir,chdir",
        ] ~ args;

    try
    {
        auto exitCode = wait(spawnProcess(traceArgs));

        if (exitCode != 0)
        {
            // If the command failed, don't bother trying to figure out implicit
            // dependencies. They will be ignored by the build system anyway.
            return exitCode;
        }

        // Parse the trace log to determine dependencies
        auto strace = Trace(logger);
        strace.parse(File(traceLog));
    }
    catch (ProcessException e)
    {
        import deps.tools.passthrough;

        // No strace. Just fallback to running the process normally.
        return passthrough(null, args);
    }

    return 0;
}

}
