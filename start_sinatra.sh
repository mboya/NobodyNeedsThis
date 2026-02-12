#!/bin/bash

# Payment Simulator Quick Start Script (Ruby/Sinatra)

echo "=========================================="
echo "Payment Simulator - Quick Start (Ruby)"
echo "=========================================="
echo ""

# Check Ruby version
echo "Checking Ruby version..."
ruby_version=$(ruby --version)
echo "✓ $ruby_version"
echo ""

# Install Bundler if not present
if ! command -v bundle &> /dev/null; then
    echo "Installing Bundler..."
    gem install bundler
    echo ""
fi

# Install dependencies
echo "Installing dependencies..."
bundle install
echo "✓ Dependencies installed"
echo ""

# Check if API server is already running
if lsof -Pi :3000 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "⚠ Port 3000 is already in use. Stopping existing process..."
    kill $(lsof -t -i:3000) 2>/dev/null
    sleep 2
fi

echo "=========================================="
echo "Starting Payment Simulator API Server..."
echo "=========================================="
echo ""
echo "The API server will start on http://localhost:3000"
echo ""
echo "Available interfaces:"
echo "  1. REST API: http://localhost:3000/api"
echo "  2. Web Interface: Open demo_interface.html in your browser"
echo "  3. CLI Demos: Run 'ruby demo_scripts.rb' in another terminal"
echo ""
echo "Quick commands:"
echo "  - rake server    : Start server"
echo "  - rake dev       : Start with auto-reload"
echo "  - rake demo      : Run interactive demos"
echo "  - rake check     : Check if server is running"
echo ""
echo "Press Ctrl+C to stop the server"
echo "=========================================="
echo ""

# Start the server
ruby app.rb
