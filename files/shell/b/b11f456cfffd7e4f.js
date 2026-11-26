"use strict";
function requireAsync(modules) {
    return new WinJS.Promise((reportComplete, reportError, reportProgress) => {
        require(modules, (...loadedModules) => {
            var result = {};
            for (let i = 0; i < modules.length; i++) {                
                result[modules[i].replace("/", "_").replace("-", "_")] = loadedModules[i];
            }
            reportComplete(result);
        }, (error) => {
            reportError(error);
        });
    });
}

(function () {
    let isDebugBuild = self.Windows && Windows.ApplicationModel.Package.current.isDevelopmentMode;
    if (isDebugBuild) {
        function _getCallerInfo() {
            let caller = null;
            try {
                let errorObj = new Error();
                caller = errorObj.stack.split("\n")[3];
            }
            catch (ex) { }
            return caller;
        }

        self.Debug = {
            assert: function (predicate, msg) {
                if (!predicate) {
                    let caller = _getCallerInfo();
                    console.log(`Assertion hit: ${msg || ""} ${caller || "" }`);
                    debugger;
                }
            },
            break: function (msg) {
                let caller = _getCallerInfo();
                console.log(`Assertion hit: ${msg || ""} ${caller || "" }`);
                debugger;
            },
            log: function (msg) {
                let caller = _getCallerInfo();
                console.log(msg + (caller || ""));
            },
        };
    }
    else {
        self.Debug = {
            assert: function () { },
            break: function () { },
            log: function () { },
        };
    }
})();