if ((typeof define === "function") && define.amd) {
    define(function () {
        return AppObjectFactory.getInstance();
    });
}
class AppObjectFactory {
    constructor() {
        this.enableSwap = false;
        this.registered = {};
    }
    static getInstance() {
        if (AppObjectFactory._instance === null) {
            AppObjectFactory._instance = new AppObjectFactory();
        }
        return AppObjectFactory._instance;
    }
    registerModule(module, object) {
        this.registered[module] = object;
    }
    getObjectFromString(className) {
        if (this.enableSwap && (className in this.registered)) {
            return this.registered[className];
        }
        return this.getContextFromString(className);
    }
    getContextFromString(className) {
        let context = window;
        let arr = className.split(".");
        try {
            for (var i = 0, len = arr.length; i < len; i++) {
                context = context[arr[i]];
            }
        }
        catch (error) {
            return null;
        }
        return context;
    }
    ;
}
AppObjectFactory._instance = null;
