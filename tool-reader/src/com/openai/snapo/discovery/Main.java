package com.openai.snapo.discovery;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import com.openai.snapo.discovery.ToolResources.ProcessInfo;
import static com.openai.snapo.discovery.ToolResources.*;

/** Lists installed tool metadata without loading application code or frontend assets. */
public final class Main {
    private static final int MAX_PROCESSES = 64;
    private Main() {}

    public static void main(String[] args) {
        int status = 0;
        try {
            discover(args);
        } catch (Exception error) {
            System.err.println("Snap-O discovery: " + message(error));
            status = 1;
        }
        // ActivityThread starts framework threads that otherwise delay the reader's exit.
        System.exit(status);
    }

    private static void discover(String[] args) throws Exception {
        if (args.length == 0 || args.length > MAX_PROCESSES) {
            throw new IllegalArgumentException("Pass between 1 and 64 process IDs.");
        }
        Set<Integer> pids = new LinkedHashSet<>();
        for (String arg : args) {
            if (!arg.matches("[1-9][0-9]{0,9}")) throw new IllegalArgumentException("Invalid process ID.");
            int pid = Integer.parseInt(arg);
            if (pid <= 0) throw new IllegalArgumentException("Invalid process ID.");
            pids.add(pid);
        }
        Context system = systemContext();
        ExecutorService executor = Executors.newFixedThreadPool(Math.min(4, pids.size()));
        ConcurrentHashMap<String, CompletableFuture<JSONObject>> packages = new ConcurrentHashMap<>();
        List<CompletableFuture<Void>> tasks = new ArrayList<>();
        for (int pid : pids) {
            tasks.add(CompletableFuture.runAsync(() -> {
                JSONObject result = new JSONObject();
                try {
                    result.put("version", 1).put("pid", pid);
                    ProcessInfo process = new ProcessInfo(pid);
                    Context context = userContext(system, process.uid / 100000);
                    PackageManager pm = context.getPackageManager();
                    ApplicationInfo app = findApp(pm, process);
                    String key = app.uid + ":" + app.packageName;
                    CompletableFuture<JSONObject> pending = new CompletableFuture<>();
                    CompletableFuture<JSONObject> previous = packages.putIfAbsent(key, pending);
                    if (previous == null) {
                        try {
                            pending.complete(readPackage(pm, app));
                        } catch (Exception error) {
                            pending.completeExceptionally(error);
                        }
                    }
                    JSONObject metadata = (previous == null ? pending : previous).get();
                    // A PID may have been reused while package resources were being read.
                    if (!process.identity.equals(new ProcessInfo(pid).identity)) {
                        throw new IllegalStateException("Process changed during discovery.");
                    }
                    result.put("processName", process.name)
                            .put("androidUserId", process.uid / 100000)
                            .put("processIdentity", process.identity)
                            .put("app", metadata);
                } catch (Exception error) {
                    try { result.put("error", message(error)); } catch (Exception ignored) { }
                }
                synchronized (System.out) {
                    System.out.println(result);
                    System.out.flush();
                }
            }, executor));
        }
        try {
            CompletableFuture.allOf(tasks.toArray(new CompletableFuture<?>[0])).get();
        } finally {
            executor.shutdownNow();
        }
    }

}
