/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./app/**/*.{js,jsx,ts,tsx}", "./components/**/*.{js,jsx,ts,tsx}"],
  presets: [require("nativewind/preset")],
  theme: {
    extend: {
      colors: {
        primary: "#00b4d8",
        "primary-dark": "#0096b7",
        background: "#0f172a",
        surface: "#1e293b",
        "surface-2": "#334155",
        border: "#475569",
        "text-primary": "#f1f5f9",
        "text-secondary": "#94a3b8",
        danger: "#ef4444",
        warning: "#f59e0b",
        success: "#22c55e",
      },
    },
  },
  plugins: [],
};
