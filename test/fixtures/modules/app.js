// Profile 3 of test/compat_test.py: njs handler for "location = /njs".
const crypto = require('crypto');

function hello(r) {
    const body = {
        njs: njs.version,
        method: r.method,
        uri: r.uri,
        args: r.args,
        sha256: crypto.createHash('sha256').update('echo').digest('hex'),
        sum: [1, 2, 3, 4].reduce((a, b) => a + b, 0),
    };
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify(body) + '\n');
}

export default { hello };
