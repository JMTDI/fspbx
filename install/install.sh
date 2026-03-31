# Restore execute bit on artisan (not a .sh but must be executable)
sudo chmod 755 /var/www/fspbx/artisan
if [ $? -eq 0 ]; then
    print_success "Execute bit restored on artisan successfully."
else
    print_error "Error occurred while restoring execute bit on artisan."
    exit 1
fi

find ... -name "*.sh" ... chmod 755