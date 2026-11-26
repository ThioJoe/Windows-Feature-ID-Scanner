define(['lib/knockout', 'legacy/bridge'], (ko, bridge) => {
    class OobeProvisioningEntryData {
        getProvisioningDataAsync() {
            let provisioningData = {
                packages: []
            };

            let pluginManager = new CloudExperienceHostAPI.Provisioning.PluginManager();
            return pluginManager.getPackagesFromProvidersAsync().then((packages) => {
                provisioningData.packages = packages;
                return provisioningData;
            });
        }
    }
    return new OobeProvisioningEntryData();
});