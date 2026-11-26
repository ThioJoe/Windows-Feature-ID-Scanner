/**
 * Wrote by Adam Hoffman <Adam.Hoffman@microsoft.com>. Inspired by
 * https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Object/entries
 */
if (!Object.entries) {
    Object.entries = function (obj) {
        const ownProps = Object.keys(obj);
        let i = ownProps.length;
        // tslint:disable-next-line: prefer-array-literal
        const resArray = new Array(i); // preallocate the Array
        while (i--) {
            resArray[i] = [ownProps[i], obj[ownProps[i]]];
        }
        return resArray;
    }
};