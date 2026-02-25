/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './layouts/**/*.html',
    './content/**/*.md',
  ],
  theme: {
    extend: {
      colors: {
        // Backgrounds
        primary: '#0a0a0f',
        secondary: '#12121a',
        tertiary: '#1a1a25',
        quaternary: '#27272a',

        // Text
        'text-primary': '#e4e4e7',
        'text-secondary': '#a1a1aa',
        'text-muted': '#71717a',

        // Accents - Cyberpunk Theme
        orange: '#FFA500',
        cyan: '#00f0ff',
        purple: '#a855f7',
        pink: '#ec4899',
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
        mono: ['JetBrains Mono', 'Fira Code', 'monospace'],
      },
      boxShadow: {
        'glow-orange': '0 0 20px rgba(255, 165, 0, 0.3)',
        'glow-cyan': '0 0 20px rgba(0, 240, 255, 0.3)',
        'glow-purple': '0 0 20px rgba(168, 85, 247, 0.3)',
        'glow-pink': '0 0 20px rgba(236, 72, 153, 0.3)',
      },
      backgroundImage: {
        'gradient-orange': 'linear-gradient(135deg, #FFA500 0%, #ff7b00 100%)',
        'gradient-cyan': 'linear-gradient(135deg, #00f0ff 0%, #0099ff 100%)',
        'gradient-purple': 'linear-gradient(135deg, #a855f7 0%, #7c3aed 100%)',
        'gradient-pink': 'linear-gradient(135deg, #ec4899 0%, #db2777 100%)',
      },
      animation: {
        'pulse-glow': 'pulse-glow 2s cubic-bezier(0.4, 0, 0.6, 1) infinite',
      },
      keyframes: {
        'pulse-glow': {
          '0%, 100%': { opacity: '1' },
          '50%': { opacity: '0.5' },
        },
      },
    },
  },
  plugins: [],
}
