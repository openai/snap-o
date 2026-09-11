package com.openai.snapo.discovery;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.util.Base64;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import com.openai.snapo.discovery.PluginResources.ProcessInfo;
import static com.openai.snapo.discovery.PluginResources.*;

/** Retrieves one metadata-referenced frontend ZIP without running the app. */
public final class FrontendMain {
    private static final Pattern SOCKET = Pattern.compile("snapo_([a-z][a-z0-9.-]{0,99})_([1-9][0-9]{0,9})");
    private static final String PREFIX = "snapo.inspector.";
    private FrontendMain() {}

    public static void main(String[] args) {
        int status = 0;
        try {
            if (args.length != 2 || args[1].length() > 16384) {
                throw new IllegalArgumentException("Pass a tool socket and expected package metadata.");
            }
            Matcher socket = SOCKET.matcher(args[0]);
            if (!socket.matches()) throw new IllegalArgumentException("Invalid tool socket name.");
            JSONObject expected = new JSONObject(new String(Base64.decode(args[1], Base64.DEFAULT), StandardCharsets.UTF_8));
            byte[] archive = readFrontend(systemContext(), Integer.parseInt(socket.group(2)), socket.group(1), expected);
            System.out.write(archive);
            System.out.flush();
        } catch (Exception error) {
            System.err.println("Snap-O frontend reader: " + message(error));
            status = 1;
        }
        System.exit(status);
    }

    private static byte[] readFrontend(Context system, int pid, String pluginId, JSONObject expected) throws Exception {
        ProcessInfo process = new ProcessInfo(pid);
        PackageManager pm = userContext(system, process.uid / 100000).getPackageManager();
        ApplicationInfo app = findApp(pm, process);
        Resources resources = pm.getResourcesForApplication(app);
        String revision = packageRevision(pm.getPackageInfo(app.packageName, 0), resources);
        JSONObject tool = readPlugin(pm, app, resources, PREFIX + pluginId);
        JSONObject frontend = tool.getJSONObject("frontend");
        if (!process.identity.equals(expected.getString("processIdentity"))
                || process.uid / 100000 != expected.getInt("androidUserId")
                || !app.packageName.equals(expected.getString("packageName"))
                || !revision.equals(expected.getString("revision"))
                || !pluginId.equals(expected.getString("inspectorId"))
                || !frontend.getString("assetPath").equals(expected.getString("assetPath"))
                || frontend.getInt("hostApiVersion") != expected.getInt("hostApiVersion")) {
            throw new IllegalStateException("Tool frontend does not match the selected app.");
        }
        byte[] archive = FrontendAssets.read(resources.getAssets(), frontend.getString("assetPath"));
        if (!process.identity.equals(new ProcessInfo(pid).identity)
                || !revision.equals(packageRevision(pm.getPackageInfo(app.packageName, 0), resources))) {
            throw new IllegalStateException("App changed while reading tool frontend.");
        }
        return archive;
    }

}
