/* Regenerated for macOS/clang (the Windows copy is MSYS2's __declspec version). Only consumed as
 * declarations: apc_image.c dlopen()s libjxl, so no symbol is linked through these. */
#ifndef JXL_THREADS_EXPORT_H
#define JXL_THREADS_EXPORT_H

#ifndef JXL_THREADS_EXPORT
#  define JXL_THREADS_EXPORT __attribute__((visibility("default")))
#endif
#ifndef JXL_THREADS_NO_EXPORT
#  define JXL_THREADS_NO_EXPORT __attribute__((visibility("hidden")))
#endif
#ifndef JXL_THREADS_DEPRECATED
#  define JXL_THREADS_DEPRECATED __attribute__((__deprecated__))
#endif
#ifndef JXL_THREADS_DEPRECATED_EXPORT
#  define JXL_THREADS_DEPRECATED_EXPORT JXL_THREADS_EXPORT JXL_THREADS_DEPRECATED
#endif
#ifndef JXL_THREADS_DEPRECATED_NO_EXPORT
#  define JXL_THREADS_DEPRECATED_NO_EXPORT JXL_THREADS_NO_EXPORT JXL_THREADS_DEPRECATED
#endif

#endif /* JXL_THREADS_EXPORT_H */
