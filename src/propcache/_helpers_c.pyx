# cython: language_level=3, freethreading_compatible=True
import sys

if sys.version_info >= (3, 9):
    from types import GenericAlias
else:

    def GenericAlias(cls, args):
        return cls


from cpython.object cimport PyObject


cdef extern from *:
    # ``PyDict_GetItemRef`` gives us a new reference to the cached value.
    # ``propcache_steal`` hands that reference to Cython as an ``object``
    # without another incref, so a cache hit costs a single incref.
    """
    #define propcache_steal(value) (value)

    /* Python 3.13+ can hand out a strong reference directly. Older
       versions only offer a borrowed reference, so incref it here; they
       have no free-threaded build, and the GIL keeps the lookup and the
       incref atomic for the string keys used by this module. */
    static int
    propcache_dict_get_item_ref(PyObject *dict, PyObject *key, PyObject **value)
    {
    #if PY_VERSION_HEX >= 0x030D0000
        return PyDict_GetItemRef(dict, key, value);
    #else
        PyObject *item = PyDict_GetItemWithError(dict, key);
        if (item == NULL) {
            if (PyErr_Occurred()) {
                return -1;
            }
            *value = NULL;
            return 0;
        }
        Py_INCREF(item);
        *value = item;
        return 1;
    #endif
    }

    /* PyObject_CallOneArg only exists since Python 3.9. The fallback
       allocates a one-element argument tuple, but it only runs on cache
       misses. */
    static PyObject *
    propcache_call_one_arg(PyObject *callable, PyObject *arg)
    {
    #if PY_VERSION_HEX >= 0x03090000
        return PyObject_CallOneArg(callable, arg);
    #else
        return PyObject_CallFunctionObjArgs(callable, arg, NULL);
    #endif
    }
    """
    object propcache_steal(PyObject* value)
    int propcache_dict_get_item_ref(
        object dict, object key, PyObject** value
    ) except -1
    object propcache_call_one_arg(object callable, object arg)


cdef class under_cached_property:
    """Use as a class method decorator.  It operates almost exactly like
    the Python `@property` decorator, but it puts the result of the
    method it decorates into the instance dict after the first call,
    effectively replacing the function it decorates with an instance
    variable.  It is, in Python parlance, a data descriptor.

    """

    cdef readonly object wrapped
    cdef object name

    def __init__(self, object wrapped):
        self.wrapped = wrapped
        self.name = wrapped.__name__

    @property
    def __doc__(self):
        return self.wrapped.__doc__

    def __get__(self, object inst, owner):
        if inst is None:
            return self
        cdef dict cache = inst._cache
        cdef PyObject* val
        # PyDict_GetItemRef returns a strong reference, a borrowed one
        # could be freed by a concurrent eviction on free-threaded builds.
        if propcache_dict_get_item_ref(cache, self.name, &val):
            return propcache_steal(val)
        result = propcache_call_one_arg(self.wrapped, inst)
        cache[self.name] = result
        return result

    def __set__(self, inst, value):
        raise AttributeError("cached property is read-only")

    __class_getitem__ = classmethod(GenericAlias)


cdef class cached_property:
    """Use as a class method decorator.  It operates almost exactly like
    the Python `@property` decorator, but it puts the result of the
    method it decorates into the instance dict after the first call,
    effectively replacing the function it decorates with an instance
    variable.  It is, in Python parlance, a data descriptor.

    """

    cdef readonly object func
    cdef object name

    def __init__(self, func):
        self.func = func
        self.name = None

    @property
    def __doc__(self):
        return self.func.__doc__

    def __set_name__(self, owner, object name):
        if self.name is None:
            self.name = name
        elif name != self.name:
            raise TypeError(
                "Cannot assign the same cached_property to two different names "
                f"({self.name!r} and {name!r})."
            )

    def __get__(self, inst, owner):
        if inst is None:
            return self
        if self.name is None:
            raise TypeError(
                "Cannot use cached_property instance"
                " without calling __set_name__ on it.")
        cdef dict cache = inst.__dict__
        cdef PyObject* val
        # PyDict_GetItemRef returns a strong reference, a borrowed one
        # could be freed by a concurrent eviction on free-threaded builds.
        if propcache_dict_get_item_ref(cache, self.name, &val):
            return propcache_steal(val)
        result = propcache_call_one_arg(self.func, inst)
        cache[self.name] = result
        return result

    __class_getitem__ = classmethod(GenericAlias)
