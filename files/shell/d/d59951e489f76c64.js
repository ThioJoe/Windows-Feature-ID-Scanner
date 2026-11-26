
define(() => {
    class OOBESettingsSelector {
        launchAsync() {
            let self = this;
            return new WinJS.Promise((completeDispatch /*, errorDispatch, progressDispatch */) => {
                self.recordAadcApplicabilityBreadcrumbAsync( 1 /* breadcrumbValue */).then(() => {
                    CloudExperienceHost.AgeAppropriateDesignCode.Eligibility.shouldRestrictionsApplyToCurrentUserAsync().then((shouldRestrictionsApply) => {
                        if (shouldRestrictionsApply && (CloudExperienceHost.getContext().personality === CloudExperienceHost.TargetPersonality.LiteWhite)) {
                            completeDispatch(CloudExperienceHost.AppResult.action2);
                        } else {
                            completeDispatch(self.selectPrivacySettingsPage());
                        }
                    }, (e) => {
                        completeDispatch(self.selectPrivacySettingsPage());
                    });
                }, (e) => {
                    completeDispatch(self.selectPrivacySettingsPage());
                });
            });
        }

        recordAadcApplicabilityBreadcrumbAsync(breadcrumbValue) {
            return CloudExperienceHostAPI.UserIntentRecordCore.setIntentPropertyDWORDAsync("OobeSettingsSelector", "FirstLogonOnAadcCompliantInstallationOverride", breadcrumbValue);
        }

        selectPrivacySettingsPage() {
            return CloudExperienceHost.Globalization.GeographicRegion.isPrivacySensitiveRegion() ? CloudExperienceHost.AppResult.action1 : CloudExperienceHost.AppResult.success;
        }
    }
    return OOBESettingsSelector;
});
