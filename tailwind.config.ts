import type { Config } from "tailwindcss";

const config: Config = {
  darkMode: "class",
  content: [
    "./src/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        // Warm neutral base — cream in light, deep navy in dark
        cream: {
          50: "#FBF8F4",
          100: "#F5EFE6",
          200: "#EDE4D3",
        },
        navy: {
          800: "#1F2937",
          900: "#141B26",
          950: "#0B0F16",
        },
        coral: {
          400: "#F4937E",
          500: "#EF6F58",
          600: "#E0553D",
        },
      },
      fontFamily: {
        // Serif headlines (Fraunces) + sans UI (Inter)
        serif: ["var(--font-fraunces)", "Georgia", "serif"],
        sans: ["var(--font-inter)", "system-ui", "sans-serif"],
      },
      animation: {
        "fade-in": "fadeIn 0.6s ease-out forwards",
        "pulse-soft": "pulseSoft 3s ease-in-out infinite",
      },
      keyframes: {
        fadeIn: {
          "0%": { opacity: "0", transform: "translateY(8px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        pulseSoft: {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.5" },
        },
      },
    },
  },
  plugins: [],
};

export default config;
