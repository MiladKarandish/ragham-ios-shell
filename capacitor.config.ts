import type { CapacitorConfig } from "@capacitor/cli";

/**
 * The iOS shell is a WKWebView pointed at the live site, not a bundled copy of
 * it. `next.config.ts` sets `output: "standalone"` and the app is built on
 * Server Components, Server Actions and cookie auth, so there is no static
 * export to embed — see `docs/architecture/ios-app.md`.
 *
 * Consequence worth knowing before changing anything here: the webview's origin
 * IS `server.url`, which is why the httpOnly session cookies work untouched and
 * why Server Actions pass their origin check.
 */
const SERVER_URL = process.env.CAP_SERVER_URL ?? "https://web.raghamapp.com";

const config: CapacitorConfig = {
  appId: "com.raghamapp.app",
  // ASCII on purpose: this names the Xcode project and its directory. The Farsi
  // name users actually see is `CFBundleDisplayName` in Info.plist.
  appName: "Ragham",
  webDir: "native/www",

  server: {
    url: SERVER_URL,
    cleartext: false,
  },

  ios: {
    // Pairs with `viewport-fit=cover` in the root layout: iOS adds no insets of
    // its own, so `env(safe-area-inset-*)` in CSS is the single source of truth
    // for clearing the notch and the home indicator. Set this to anything else
    // and the safe-area padding is applied twice.
    contentInset: "never",
    backgroundColor: "#f4f4f4",
    // Marks every request from the shell, so the web app can tell it is running
    // natively even server-side — `isNativeShell()` only works after hydration.
    appendUserAgent: "RaghamiOS",
  },

  plugins: {
    StatusBar: {
      // "LIGHT" means dark text, for a light background — the plugin maps it to
      // `.darkContent`. Set here rather than through the JS API so it is right
      // from the first frame instead of flipping after hydration.
      style: "LIGHT",
      // The webview runs under the status bar; `env(safe-area-inset-top)` in the
      // page is what keeps content clear of it.
      overlaysWebView: true,
    },
    PushNotifications: {
      presentationOptions: ["badge", "sound", "alert"],
    },
    SplashScreen: {
      // The shell loads over the network, so the splash covers a remote page
      // load, not a local one. `hideNativeSplash()` drops it as soon as the app
      // paints; this duration is only the backstop for when the site never
      // answers — without it a failed load would sit under the splash forever.
      launchAutoHide: true,
      launchShowDuration: 3000,
      backgroundColor: "#f4f4f4",
      showSpinner: false,
    },
  },
};

export default config;
