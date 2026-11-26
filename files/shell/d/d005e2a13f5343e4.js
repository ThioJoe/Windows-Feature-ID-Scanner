class RequirePathConfig {
    constructor(root) {
        this.baseUrl = root + '/js';
        this.paths = {
            legacy: '/js',
            lib: '/lib',
            winjs: '/Microsoft.WinJS-reduced/js',
            jsCommon: this.baseUrl + '/common',
            jsTemplates: '/webapps/templates/js',
            pageView: root + '/view',
            viewTemplates: root + '/view/templates',
            inclusiveOobeJsCommon: '/webapps/inclusiveOobe/js/common',
            inclusiveOobeViewTemplates: '/webapps/inclusiveOobe/view/templates',
            aOobeJsCommon: '/webapps/AOobe/js/common',
            aOobeViewTemplates: '/webapps/AOobe/view/templates',
            viewCommonTemplates: '/webapps/templates/view',
            appLaunchers: this.baseUrl + '/appLaunchers',
            optional: '/lib/optional',
            sample: '/samples',
            data: '/data',
            coreView: '/core/view',
            corejs: '/core/js'
        };

        this.map = {
            '*': {
                'lib/knockout': 'lib/knockout-3.4.0',
                'lib/knockout-winjs': 'lib/knockout-winjs-wrapper'
            }
        };

        this.waitSeconds = 30;
    }
}
