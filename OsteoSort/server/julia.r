# load Julia environment
showModal(modalDialog(title = "Loading Julia Environment...", easyClose = FALSE, footer = NULL))
sysimage <- "./OsteoSort.so"
if (file.exists(sysimage)) {
    julia_setup(sysimage_path = sysimage)
} else {
    julia_setup()
    julia_command('push!(LOAD_PATH, "../OSJ")')
    julia_command("using OSJ")
}
removeModal()
