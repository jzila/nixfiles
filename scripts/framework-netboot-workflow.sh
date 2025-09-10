#!/usr/bin/env bash
# Complete workflow script for Framework Desktop netboot installation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_step() {
    echo -e "${BLUE}$1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

usage() {
    echo "Framework Desktop NixOS Netboot Installation Workflow"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  serve                Start netboot server (Phase 1)"
    echo "  scan <remote_host>   Scan remote hardware (Phase 2)"  
    echo "  install <remote_host> Complete installation (Phase 3)"
    echo "  workflow             Interactive complete workflow"
    echo "  help                 Show this help"
    echo ""
    echo "Options for scan/install:"
    echo "  -u, --user USER      SSH username (default: root)"
    echo "  -t, --target HOST    Target host config (default: argo)"
    echo ""
    echo "Examples:"
    echo "  $0 serve                           # Start netboot server"
    echo "  $0 scan 192.168.1.100             # Scan hardware on Framework"
    echo "  $0 install 192.168.1.100          # Install NixOS"
    echo "  $0 workflow                       # Interactive workflow"
}

serve_netboot() {
    print_step "🚀 Phase 1: Starting netboot server..."
    exec "$SCRIPT_DIR/serve-netboot.sh"
}

scan_hardware() {
    local remote_host="$1"
    shift
    print_step "🔍 Phase 2: Scanning hardware on $remote_host..."
    "$SCRIPT_DIR/scan-remote-hardware.sh" "$remote_host" "$@"
    print_success "Hardware scan complete"
}

install_nixos() {
    local remote_host="$1"
    shift
    print_step "🔧 Phase 3: Installing NixOS on $remote_host..."
    "$SCRIPT_DIR/install-remote-nixos.sh" "$remote_host" "$@"
    print_success "NixOS installation complete"
}

interactive_workflow() {
    echo "🖥️  Framework Desktop NixOS Installation Workflow"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "This workflow will guide you through:"
    echo "  1. Building and serving the netboot image"
    echo "  2. Booting your Framework Desktop over network"  
    echo "  3. Scanning hardware and updating configuration"
    echo "  4. Installing NixOS"
    echo ""
    
    print_warning "Prerequisites:"
    echo "  - Framework Desktop connected to same network"
    echo "  - SSH key added to netboot configuration"
    echo "  - No USB drives needed!"
    echo ""
    
    echo "❓ Ready to start? [y/N]"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted by user"
        exit 0
    fi
    
    # Phase 1: Start netboot server
    echo ""
    print_step "📋 Phase 1: Netboot Server Setup"
    echo "We'll start the netboot server. This will:"
    echo "  - Build the NixOS installer image"
    echo "  - Start HTTP server to serve boot files"
    echo "  - Display Framework BIOS setup instructions"
    echo ""
    echo "❓ Start netboot server? [Y/n]"
    read -r start_server
    if [[ ! "$start_server" =~ ^[Nn]$ ]]; then
        print_step "🚀 Starting netboot server..."
        echo "⚠️  The server will start in a new process."
        echo "   Come back to this terminal after Framework boots."
        echo ""
        echo "Press Enter to continue..."
        read -r
        
        # Start server in background and get its PID
        "$SCRIPT_DIR/serve-netboot.sh" &
        SERVER_PID=$!
        
        echo ""
        print_success "Netboot server started (PID: $SERVER_PID)"
        print_warning "Leave the server running and follow the BIOS setup instructions"
        echo ""
    fi
    
    # Phase 2: Wait for Framework boot and scan hardware
    echo ""
    print_step "📋 Phase 2: Framework Boot and Hardware Scan"
    echo "Now:"
    echo "  1. Power on your Framework Desktop"
    echo "  2. Press F2 to enter BIOS setup"
    echo "  3. Enable Network Boot"
    echo "  4. Set HTTP Boot URL (shown by netboot server)"
    echo "  5. Save and reboot"
    echo "  6. Framework should boot into NixOS installer"
    echo ""
    echo "❓ Has the Framework booted into NixOS installer? [y/N]"
    read -r framework_booted
    if [[ "$framework_booted" =~ ^[Yy]$ ]]; then
        echo ""
        echo "❓ What's the Framework's IP address?"
        echo "   (Check the netboot server output or run 'ip addr' on Framework)"
        read -r framework_ip
        
        if [[ -n "$framework_ip" ]]; then
            print_step "🔍 Scanning hardware on $framework_ip..."
            if "$SCRIPT_DIR/scan-remote-hardware.sh" "$framework_ip"; then
                print_success "Hardware scan completed and configuration updated"
                
                # Phase 3: Install NixOS
                echo ""
                print_step "📋 Phase 3: NixOS Installation"
                echo "❓ Proceed with NixOS installation? [Y/n]"
                read -r proceed_install
                if [[ ! "$proceed_install" =~ ^[Nn]$ ]]; then
                    print_step "🔧 Installing NixOS on $framework_ip..."
                    if "$SCRIPT_DIR/install-remote-nixos.sh" "$framework_ip"; then
                        print_success "🎉 Complete! Framework Desktop is running NixOS."
                        
                        # Cleanup
                        if [[ -n "${SERVER_PID:-}" ]]; then
                            print_step "🧹 Cleaning up netboot server..."
                            kill $SERVER_PID 2>/dev/null || true
                            print_success "Netboot server stopped"
                        fi
                        
                        echo ""
                        echo "🚀 Your Framework Desktop is ready!"
                        echo "   You can now reboot it to start using NixOS."
                        exit 0
                    else
                        print_error "Installation failed"
                        exit 1
                    fi
                fi
            else
                print_error "Hardware scan failed"
                exit 1
            fi
        fi
    fi
    
    echo ""
    print_warning "Workflow incomplete. You can:"
    echo "  - Run individual commands manually"
    echo "  - Restart this workflow: $0 workflow"
    echo ""
    if [[ -n "${SERVER_PID:-}" ]]; then
        echo "❓ Stop the netboot server? [y/N]"
        read -r stop_server
        if [[ "$stop_server" =~ ^[Yy]$ ]]; then
            kill $SERVER_PID 2>/dev/null || true
            print_success "Netboot server stopped"
        fi
    fi
}

# Parse command line arguments
COMMAND=""
REMOTE_HOST=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        serve|scan|install|workflow|help)
            COMMAND="$1"
            shift
            ;;
        -*)
            EXTRA_ARGS+=("$1")
            if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                EXTRA_ARGS+=("$2")
                shift
            fi
            shift
            ;;
        *)
            if [[ -z "$REMOTE_HOST" ]]; then
                REMOTE_HOST="$1"
            else
                EXTRA_ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

# Execute command
case "${COMMAND:-}" in
    serve)
        serve_netboot
        ;;
    scan)
        if [[ -z "$REMOTE_HOST" ]]; then
            print_error "Remote host required for scan command"
            echo ""
            usage
            exit 1
        fi
        scan_hardware "$REMOTE_HOST" "${EXTRA_ARGS[@]}"
        ;;
    install)
        if [[ -z "$REMOTE_HOST" ]]; then
            print_error "Remote host required for install command"
            echo ""
            usage
            exit 1
        fi
        install_nixos "$REMOTE_HOST" "${EXTRA_ARGS[@]}"
        ;;
    workflow)
        interactive_workflow
        ;;
    help|"")
        usage
        ;;
    *)
        print_error "Unknown command: $COMMAND"
        echo ""
        usage
        exit 1
        ;;
esac