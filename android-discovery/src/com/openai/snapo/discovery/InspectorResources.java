package com.openai.snapo.discovery;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.content.res.XmlResourceParser;
import android.graphics.Bitmap;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Shader;
import android.graphics.drawable.AdaptiveIconDrawable;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.os.Looper;
import android.os.UserHandle;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import org.xmlpull.v1.XmlPullParser;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.util.Set;

/** Shared package and resource access for the discovery and frontend tools. */
final class InspectorResources {
    private static final String PREFIX = "snapo.inspector.";
    private static final int ICON_SIZE = 96;
    private InspectorResources() {}

    static Context systemContext() throws Exception {
        Looper.prepareMainLooper();
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Object thread = activityThread.getMethod("systemMain").invoke(null);
        return (Context) activityThread.getMethod("getSystemContext").invoke(thread);
    }

    static Context userContext(Context context, int id) throws Exception {
        UserHandle user = (UserHandle) UserHandle.class.getMethod("of", int.class).invoke(null, id);
        return (Context) Context.class.getMethod("createContextAsUser", UserHandle.class, int.class)
                .invoke(context, user, 0);
    }

    static ApplicationInfo findApp(PackageManager pm, ProcessInfo process) throws Exception {
        String[] candidates = pm.getPackagesForUid(process.uid);
        if (candidates == null || candidates.length == 0) {
            throw new IllegalArgumentException("No installed package owns the process UID.");
        }
        String hint = process.name.split(":", 2)[0];
        for (String name : candidates) {
            ApplicationInfo app = pm.getApplicationInfo(name, PackageManager.GET_META_DATA);
            if (app.uid == process.uid && (name.equals(hint) || process.name.equals(app.processName))) return app;
        }
        if (candidates.length == 1) return pm.getApplicationInfo(candidates[0], PackageManager.GET_META_DATA);
        throw new IllegalArgumentException("Several packages share this process UID.");
    }

    static JSONObject readPackage(PackageManager pm, ApplicationInfo app, Set<String> ids) throws Exception {
        PackageInfo installed = pm.getPackageInfo(app.packageName, 0);
        Resources resources = pm.getResourcesForApplication(app);
        JSONArray inspectors = new JSONArray();
        JSONArray errors = new JSONArray();
        if (app.metaData != null) {
            for (String id : ids) {
                String key = PREFIX + id;
                if (!app.metaData.containsKey(key)) continue;
                try {
                    inspectors.put(readInspector(pm, app, resources, key));
                } catch (Exception error) {
                    errors.put(new JSONObject().put("key", key).put("error", message(error)));
                }
            }
        }
        JSONObject result = new JSONObject()
                .put("packageName", app.packageName)
                .put("name", pm.getApplicationLabel(app).toString())
                .put("revision", packageRevision(installed, resources))
                .put("inspectors", inspectors)
                .put("errors", errors);
        try { result.put("iconBase64", renderAppIcon(pm, app, resources)); } catch (Exception ignored) { }
        return result;
    }

    static String packageRevision(PackageInfo installed, Resources resources) {
        long version = Build.VERSION.SDK_INT >= 28 ? installed.getLongVersionCode() : installed.versionCode;
        return version + ":" + installed.lastUpdateTime + ":" + resources.getConfiguration();
    }

    private static String renderAppIcon(PackageManager pm, ApplicationInfo app, Resources resources) {
        if (Build.VERSION.SDK_INT >= 25) {
            try {
                // Android keeps roundIcon outside its public SDK; missing access must not break discovery.
                int roundIcon = ApplicationInfo.class.getField("roundIconRes").getInt(app);
                if (roundIcon != 0) return renderIcon(resources.getDrawable(roundIcon, null), true);
            } catch (Exception ignored) { }
        }
        return renderIcon(pm.getApplicationIcon(app), true);
    }

    static JSONObject readInspector(
            PackageManager pm, ApplicationInfo app, Resources resources, String key) throws Exception {
        try (XmlResourceParser xml = app.loadXmlMetaData(pm, key)) {
            if (xml == null) throw new IllegalArgumentException("Missing inspector XML resource.");
            int event;
            do { event = xml.next(); } while (event != XmlPullParser.START_TAG && event != XmlPullParser.END_DOCUMENT);
            if (event != XmlPullParser.START_TAG || !"inspector".equals(xml.getName())
                    || integer(xml, resources, "version") != 1) {
                throw new IllegalArgumentException("Unsupported inspector descriptor.");
            }
            String id = text(xml, resources, "id");
            String name = text(xml, resources, "name");
            int protocol = integer(xml, resources, "protocolVersion");
            if (!id.matches("[a-z][a-z0-9.-]{0,99}") || !key.equals(PREFIX + id)
                    || name.trim().isEmpty()
                    || name.length() > 200 || protocol < 1) {
                throw new IllegalArgumentException("Invalid inspector descriptor fields.");
            }
            JSONObject result = new JSONObject().put("id", id).put("name", name)
                    .put("protocolVersion", protocol);
            if (xml.getAttributeValue(null, "frontendAssets") != null) {
                String assetPath = text(xml, resources, "frontendAssets");
                int hostApiVersion = integer(xml, resources, "hostApiVersion");
                if (!FrontendAssets.validPath(assetPath) || hostApiVersion < 1) {
                    throw new IllegalArgumentException("Invalid inspector frontend.");
                }
                result.put("frontend", new JSONObject().put("assetPath", assetPath)
                        .put("hostApiVersion", hostApiVersion));
            }
            int icon = xml.getAttributeResourceValue(null, "icon", 0);
            if (icon != 0) result.put("iconBase64", renderIcon(resources.getDrawable(icon, null)));
            return result;
        }
    }

    private static String text(XmlResourceParser xml, Resources resources, String name) {
        int id = xml.getAttributeResourceValue(null, name, 0);
        String value = id == 0 ? xml.getAttributeValue(null, name) : resources.getString(id);
        if (value == null) throw new IllegalArgumentException("Missing " + name + ".");
        return value;
    }

    private static int integer(XmlResourceParser xml, Resources resources, String name) {
        int id = xml.getAttributeResourceValue(null, name, 0);
        return id == 0 ? Integer.parseInt(text(xml, resources, name)) : resources.getInteger(id);
    }

    private static String renderIcon(Drawable icon) {
        return renderIcon(icon, false);
    }

    private static String renderIcon(Drawable icon, boolean roundAdaptiveIcon) {
        Bitmap bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888);
        Bitmap circular = null;
        try {
            icon.setBounds(0, 0, ICON_SIZE, ICON_SIZE);
            Canvas canvas = new Canvas(bitmap);
            if (roundAdaptiveIcon && Build.VERSION.SDK_INT >= 26 && icon instanceof AdaptiveIconDrawable) {
                AdaptiveIconDrawable adaptive = (AdaptiveIconDrawable) icon;
                // Draw the layers with Android's bounds, replacing the device's mask with a circle.
                if (adaptive.getBackground() != null) adaptive.getBackground().draw(canvas);
                if (adaptive.getForeground() != null) adaptive.getForeground().draw(canvas);
                circular = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888);
                Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
                paint.setShader(new BitmapShader(bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP));
                float radius = ICON_SIZE / 2f;
                new Canvas(circular).drawCircle(radius, radius, radius, paint);
            } else {
                icon.draw(canvas);
            }
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            if (!(circular == null ? bitmap : circular).compress(Bitmap.CompressFormat.PNG, 100, output)) {
                throw new IllegalArgumentException("Unable to encode icon.");
            }
            return Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP);
        } finally {
            if (circular != null) circular.recycle();
            bitmap.recycle();
        }
    }

    static String message(Exception error) {
        Throwable cause = error;
        while (cause.getCause() != null) cause = cause.getCause();
        return cause.getMessage() == null ? cause.getClass().getSimpleName() : cause.getMessage();
    }

    static final class ProcessInfo {
        final int uid;
        final String name;
        final String identity;

        ProcessInfo(int pid) throws Exception {
            String base = "/proc/" + pid + "/";
            String status = read(base + "status");
            int parsedUid = -1;
            for (String line : status.split("\n")) {
                if (line.startsWith("Uid:")) parsedUid = Integer.parseInt(line.substring(4).trim().split("\\s+")[0]);
            }
            if (parsedUid < 0) throw new IllegalArgumentException("Missing process UID.");
            uid = parsedUid;
            name = read(base + "cmdline").split("\u0000", 2)[0];
            String stat = read(base + "stat");
            String start = stat.substring(stat.lastIndexOf(')') + 2).split("\\s+")[19];
            identity = read("/proc/sys/kernel/random/boot_id").trim() + ":" + pid + ":" + start;
        }

        private static String read(String path) throws Exception {
            try (FileInputStream input = new FileInputStream(path)) {
                ByteArrayOutputStream output = new ByteArrayOutputStream();
                byte[] buffer = new byte[4096];
                int size;
                while ((size = input.read(buffer)) != -1) {
                    if (output.size() + size > 65536) throw new IllegalArgumentException("Process metadata is too large.");
                    output.write(buffer, 0, size);
                }
                return new String(output.toByteArray(), StandardCharsets.UTF_8);
            }
        }
    }
}
